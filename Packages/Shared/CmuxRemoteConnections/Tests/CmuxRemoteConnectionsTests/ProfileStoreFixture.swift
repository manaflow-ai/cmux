import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CmuxRemoteConnections

/// Test-owned on-disk SQLite fixture; never accesses user storage or credentials.
struct ProfileStoreFixture {
    let directory: URL
    let url: URL
    let vaultID = UUID()

    init() throws {
        directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-profiles-" + UUID().uuidString)
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("profiles.sqlite3")
    }

    func cleanup() { try? FileManager().removeItem(at: directory) }

    func store(account: String = "private-owner", vault: UUID? = nil, key: SymmetricKey) throws -> MobileRemoteProfileStore {
        try MobileRemoteProfileStore(
            databaseURL: url, accountID: account, vaultID: vault ?? vaultID, key: key
        )
    }

    func profile(id: UUID = UUID(), host: String = "private.example.com") throws -> MobileRemoteProfile {
        try MobileRemoteProfile(
            id: id, host: host, username: "private-user",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func exec(_ sql: String) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close_v2(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    func scalar(_ sql: String) throws -> Int64 {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement)
        defer { sqlite3_finalize(prepared) }
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        return sqlite3_column_int64(prepared, 0)
    }
}
