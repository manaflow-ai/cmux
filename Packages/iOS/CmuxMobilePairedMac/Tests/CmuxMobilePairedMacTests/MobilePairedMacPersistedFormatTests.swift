import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

/// Loads every persisted-formats/mobile-paired-mac-store/v*.json fixture through the real store, as this build
/// and as a stand-in for a newer build's file (persisted-formats/README-ios-formats.md).
@Suite struct MobilePairedMacPersistedFormatTests {
    struct Fixture: Decodable {
        var userVersion: Int32
        var sql: [String]
        var newerBuildSQL: [String]
        var macs: [ExpectedMac]

        enum CodingKeys: String, CodingKey {
            case userVersion = "user_version"
            case sql
            case newerBuildSQL = "newer_build_sql"
            case macs
        }
    }

    struct ExpectedMac: Decodable {
        var macDeviceID: String
        var displayName: String?
        var stackUserID: String?
        var teamID: String?
        var instanceTag: String?
        var customName: String?
        var customColor: String?
        var customIcon: String?
        var isActive: Bool
        var createdAt: Double
        var lastSeenAt: Double
        var connectionMethod: String?
        var directAddresses: String?
        var routeIDs: [String]
        var legacyTailscaleRoutes: Int
    }

    @Test func pairedMacStoreFixturesLoad() async throws {
        let directory = try Self.fixtureDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("v") && $0.hasSuffix(".json") }
            .sorted()
        #expect(files.contains("v\(MobilePairedMacStore.currentSchemaVersion).json"))
        for file in files {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: directory.appendingPathComponent(file))
            )
            try await check(fixture, file: file, asNewerBuild: false)
            if !fixture.newerBuildSQL.isEmpty {
                try await check(fixture, file: file, asNewerBuild: true)
            }
        }
    }

    private func check(_ fixture: Fixture, file: String, asNewerBuild: Bool) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("paired-macs.sqlite3")
        let newerVersion = max(fixture.userVersion, MobilePairedMacStore.currentSchemaVersion) + 1
        var statements = fixture.sql + ["PRAGMA user_version = \(fixture.userVersion)"]
        if asNewerBuild {
            statements += fixture.newerBuildSQL + ["PRAGMA user_version = \(newerVersion)"]
        }
        try Self.run(statements, at: url)

        let label = "\(file)\(asNewerBuild ? " (newer build)" : "")"
        let store = try MobilePairedMacStore(databaseURL: url)
        let loaded = try await store.loadAll()
        try Self.expect(loaded, equal: fixture.macs, label: label)
        let expectedVersion = asNewerBuild ? newerVersion : MobilePairedMacStore.currentSchemaVersion
        #expect(try Self.userVersion(at: url) == expectedVersion, "\(label): user_version")

        // A second open reads the same list: the migration is complete, not repeated.
        let reopened = try MobilePairedMacStore(databaseURL: url)
        let reloaded = try await reopened.loadAll()
        try Self.expect(reloaded, equal: fixture.macs, label: "\(label) reopened")

        guard asNewerBuild else { return }
        // This build rewrites one Mac's routes; the rows only the newer build can read must survive it.
        let rowsBefore = try Self.count("SELECT COUNT(*) FROM mac_routes WHERE kind NOT IN ('tailscale', 'iroh', 'websocket', 'debug_loopback')", at: url)
        #expect(rowsBefore > 0, "\(label): fixture has a newer route row")
        let anonymous = try #require(fixture.macs.first { $0.stackUserID == nil })
        let route = try CmxAttachRoute(
            id: "rewritten", kind: .tailscale, endpoint: .hostPort(host: "10.0.0.6", port: 9000)
        )
        try await reopened.upsert(
            macDeviceID: anonymous.macDeviceID, displayName: nil, routes: [route],
            markActive: false, stackUserID: nil
        )
        let after = try await reopened.loadAll()
        let anonymousAfter = try #require(after.first { $0.macDeviceID == anonymous.macDeviceID })
        #expect(anonymousAfter.routes.map(\.id) == ["rewritten"], "\(label): rewritten routes")
        #expect(try Self.count("SELECT COUNT(*) FROM mac_routes WHERE kind NOT IN ('tailscale', 'iroh', 'websocket', 'debug_loopback')", at: url) == rowsBefore, "\(label): newer route rows kept")
        #expect(try Self.count("SELECT COUNT(*) FROM paired_macs WHERE future_note = 'kept'", at: url) == Int64(fixture.macs.count), "\(label): newer column kept")
        #expect(try Self.userVersion(at: url) == newerVersion, "\(label): user_version kept")
    }

    private static func expect(_ macs: [MobilePairedMac], equal expected: [ExpectedMac], label: String) throws {
        #expect(macs.map(\.macDeviceID) == expected.map(\.macDeviceID), "\(label): Macs")
        for (mac, want) in zip(macs, expected) {
            let at = "\(label) \(want.macDeviceID)"
            #expect(mac.displayName == want.displayName, "\(at): displayName")
            #expect(mac.stackUserID == want.stackUserID, "\(at): stackUserID")
            #expect(mac.teamID == want.teamID, "\(at): teamID")
            #expect(mac.instanceTag == want.instanceTag, "\(at): instanceTag")
            #expect(mac.customName == want.customName, "\(at): customName")
            #expect(mac.customColor == want.customColor, "\(at): customColor")
            #expect(mac.customIcon == want.customIcon, "\(at): customIcon")
            #expect(mac.isActive == want.isActive, "\(at): isActive")
            #expect(mac.createdAt.timeIntervalSince1970 == want.createdAt, "\(at): createdAt")
            #expect(mac.lastSeenAt.timeIntervalSince1970 == want.lastSeenAt, "\(at): lastSeenAt")
            #expect(mac.connectionMethodRawValue == want.connectionMethod, "\(at): connectionMethod")
            #expect(mac.directAddressesRawJSON == want.directAddresses, "\(at): directAddresses")
            #expect(mac.routes.map(\.id) == want.routeIDs, "\(at): routes")
            #expect((mac.legacyTailscaleRoutes ?? []).count == want.legacyTailscaleRoutes, "\(at): legacy grants")
        }
    }

    /// The repo's persisted-formats/mobile-paired-mac-store, found from this file's path.
    static func fixtureDirectory(filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let formats = directory.appendingPathComponent("persisted-formats")
            if FileManager.default.fileExists(atPath: formats.appendingPathComponent("formats.toml").path) {
                return formats.appendingPathComponent("mobile-paired-mac-store")
            }
            directory = directory.deletingLastPathComponent()
        }
        throw FixtureError.notFound(filePath)
    }

    enum FixtureError: Error {
        case notFound(String)
        case sqlite(String)
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw FixtureError.sqlite("open \(url.path)")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func run(_ statements: [String], at url: URL) throws {
        try withDatabase(at: url) { database in
            for statement in statements {
                guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                    throw FixtureError.sqlite("\(String(cString: sqlite3_errmsg(database))): \(statement)")
                }
            }
        }
    }

    private static func count(_ sql: String, at url: URL) throws -> Int64 {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw FixtureError.sqlite("\(String(cString: sqlite3_errmsg(database))): \(sql)")
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private static func userVersion(at url: URL) throws -> Int32 {
        Int32(try count("PRAGMA user_version", at: url))
    }
}
