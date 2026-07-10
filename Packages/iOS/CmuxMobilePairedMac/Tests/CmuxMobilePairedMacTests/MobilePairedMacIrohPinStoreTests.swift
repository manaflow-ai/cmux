import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacIrohPinStoreTests {
    private func makeStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func irohRoute(endpointID: String = "endpoint-a") throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(id: endpointID, relayHint: nil, directAddrs: [], relayURL: nil)
        )
    }

    @Test func migratesV4RowsToV5WithNilIrohPin() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let seed = """
            CREATE TABLE paired_macs (
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                display_name TEXT,
                stack_user_id TEXT,
                team_id TEXT,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0,
                custom_name TEXT,
                custom_color TEXT,
                custom_icon TEXT,
                PRIMARY KEY (mac_device_id, owner_key)
            );
            CREATE TABLE mac_routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
            INSERT INTO paired_macs
                (mac_device_id, owner_key, display_name, stack_user_id, team_id, created_at, last_seen_at, is_active)
                VALUES ('mac-v4', 'user-1' || char(31) || 'team-a', 'V4 Mac', 'user-1', 'team-a', 1, 2, 1);
            PRAGMA user_version = 4;
        """
        #expect(sqlite3_exec(handle, seed, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let store = try MobilePairedMacStore(databaseURL: url)
        let rows = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.map(\.macDeviceID) == ["mac-v4"])
        #expect(rows.first?.pinnedIrohEndpointID == nil)

        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == MobilePairedMacStore.currentSchemaVersion)
        sqlite3_finalize(stmt)
        sqlite3_close(check)
    }

    @Test func irohPinPersistsAcrossReopenAndUpsertCannotModifyIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")

        do {
            let store = try MobilePairedMacStore(databaseURL: url)
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                routes: [try irohRoute(endpointID: "endpoint-a")],
                markActive: true,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 10)
            )
            try await store.setPinnedIrohEndpointID(
                macDeviceID: "mac-a",
                endpointID: "endpoint-a",
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 11)
            )
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                routes: [try irohRoute(endpointID: "attacker-endpoint")],
                markActive: true,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 12)
            )
        }

        let reopened = try MobilePairedMacStore(databaseURL: url)
        let row = try #require(try await reopened.loadAll(stackUserID: "user-1", teamID: "team-a").first)
        #expect(row.routes.first?.irohPeerIDForTesting == "attacker-endpoint")
        #expect(row.pinnedIrohEndpointID == "endpoint-a")
    }

    @Test func removeDeletesPinnedIrohEndpointIDWithRow() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [try irohRoute()],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        try await store.setPinnedIrohEndpointID(
            macDeviceID: "mac-a",
            endpointID: "endpoint-a",
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )
        try await store.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: "team-a")

        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-a").isEmpty)
    }

    @Test func plainUpsertRestorePathLeavesIrohPinNil() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.upsert(
            macDeviceID: "restored-mac",
            displayName: "Restored",
            routes: [try irohRoute(endpointID: "restored-endpoint")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date()
        )

        let row = try #require(try await store.loadAll(stackUserID: "user-1", teamID: "team-a").first)
        #expect(row.pinnedIrohEndpointID == nil)
    }
}

private extension CmxAttachRoute {
    var irohPeerIDForTesting: String? {
        guard case let .peer(id, _, _, _) = endpoint else { return nil }
        return id
    }
}
