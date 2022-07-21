import XCTest
import SQLite

class StatementTests: SQLiteTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try createUsersTable()
    }

    func test_cursor_to_blob() {
        try! insertUsers("alice")
        let statement = try! db.prepare("SELECT email FROM users")
        XCTAssert(try! statement.step())
        let blob = statement.row[0] as Blob
        XCTAssertEqual("alice@example.com", String(bytes: blob.bytes, encoding: .utf8)!)
    }

    func test_zero_sized_blob_returns_null() {
        let blobs = Table("blobs")
        let blobColumn = Expression<Blob>("blob_column")
        try! db.run(blobs.create { $0.column(blobColumn) })
        try! db.run(blobs.insert(blobColumn <- Blob(bytes: [])))
        let blobValue = try! db.scalar(blobs.select(blobColumn).limit(1, offset: 0))
        XCTAssertEqual([], blobValue.bytes)
    }

    func test_prepareRowIterator() {
        let names = ["a", "b", "c"]
        try! insertUsers(names)

        let emailColumn = Expression<String>("email")
        let statement = try! db.prepare("SELECT email FROM users")
        let emails = try! statement.prepareRowIterator().map { $0[emailColumn] }

        XCTAssertEqual(names.map({ "\($0)@example.com" }), emails.sorted())
    }

    /// Check that a statement reset will close the implicit transaction, allowing wal file to checkpoint
    func test_reset_statement() throws {
        // Remove old test db if any
        let path = "\(NSTemporaryDirectory())/SQLite.swift Tests.sqlite3"
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-shm")
        try? FileManager.default.removeItem(atPath: path + "-wal")

        // create new db on disk in wal mode
        let db = try Connection(.uri(path))
        let url = URL(fileURLWithPath: db.description)
        XCTAssertEqual(url.lastPathComponent, "SQLite.swift Tests.sqlite3")
        try db.run("PRAGMA journal_mode=WAL;")

        // create users table
        try db.execute("""
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                age INTEGER,
                salary REAL,
                admin BOOLEAN NOT NULL DEFAULT 0 CHECK (admin IN (0, 1)),
                manager_id INTEGER,
                created_at DATETIME,
                FOREIGN KEY(manager_id) REFERENCES users(id)
            )
            """
        )

        // insert single row
        try db.run("INSERT INTO \"users\" (email, age, admin) values (?, ?, ?)",
                   "alice@example.com", 1.datatypeValue, false.datatypeValue)

        // prepare a statement and read a single row. This will incremeent the cursor which
        // prevents the implicit transaction from closing.
        // https://www.sqlite.org/lang_transaction.html#implicit_versus_explicit_transactions
        let statement = try db.prepare("SELECT email FROM users")
        XCTAssert(try statement.step())
        let blob = statement.row[0] as Blob
        XCTAssertEqual("alice@example.com", String(bytes: blob.bytes, encoding: .utf8)!)

        // verify that the transaction is not closed, which prevents wal_checkpoints (both explicit and auto)
        do {
            try db.run("pragma wal_checkpoint(truncate)")
            XCTFail("Database should be locked")
        } catch {
            // pass
        }

        // reset the prepared statement, allowing the implicit transaction to close
        statement.reset()

        // truncate succeeds
        try db.run("pragma wal_checkpoint(truncate)")
    }

}
