import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacInstanceTagTests {
    @Test func conditionalRestoreAddsDistinctTagWithoutOverwritingNewerAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let routeA = try CmxAttachRoute(
            id: "a", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 8001)
        )
        let routeB = try CmxAttachRoute(
            id: "b", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.2", port: 8002)
        )
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio B",
            routes: [routeB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )

        let restored = try await store.upsertIfNewer(
            macDeviceID: "mac-a",
            displayName: "Stale A",
            routes: [routeA],
            instanceTag: "feature-a",
            customName: "Stale custom name",
            customColor: "palette:1",
            customIcon: "desktopcomputer",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )

        #expect(restored)
        let records = try await store.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(Set(records.compactMap(\.instanceTag)) == ["feature-a", "feature-b"])
        let current = try #require(await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        ))
        #expect(current.instanceTag == "feature-b")
        #expect(current.routes == [routeB])
        #expect(current.displayName == "Studio B")
        #expect(current.customName == nil)
        #expect(current.lastSeenAt == Date(timeIntervalSince1970: 20))
    }

    @Test func conditionalRestoreCannotStealAConcurrentActiveSelection() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let routeA = try route(id: "a", port: 51_001)
        let routeB = try route(id: "b", port: 51_002)

        try await store.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [routeB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )
        #expect(try await store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        )?.macDeviceID == "mac-b")
        let restored = try await store.upsertIfNewer(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [routeA],
            instanceTag: "feature-a",
            customName: nil,
            customColor: nil,
            customIcon: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )

        #expect(restored)
        let records = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(records.first(where: { $0.macDeviceID == "mac-a" })?.isActive == false)
        #expect(records.first(where: { $0.macDeviceID == "mac-b" })?.isActive == true)
    }

    @Test func conditionalRestorePreservesConcurrentSameMacActivation() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = try route(id: "a", port: 51_001)
        try await store.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [route],
            instanceTag: "feature-a", markActive: false,
            stackUserID: "user-1", teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.setActive(
            macDeviceID: "mac-a", stackUserID: "user-1", teamID: "team-a"
        )

        _ = try await store.upsertIfNewer(
            macDeviceID: "mac-a", displayName: "A", routes: [route],
            instanceTag: "feature-a", customName: nil, customColor: nil,
            customIcon: nil, markActive: false, stackUserID: "user-1",
            teamID: "team-a", now: Date(timeIntervalSince1970: 10)
        )

        #expect(try await store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        )?.macDeviceID == "mac-a")
    }

    @Test func conditionalRestorePreservesConcurrentSelectionClear() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = try route(id: "a", port: 51_001)
        try await store.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [route],
            instanceTag: "feature-a", markActive: true,
            stackUserID: "user-1", teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.clearActive(stackUserID: "user-1", teamID: "team-a")

        _ = try await store.upsertIfNewer(
            macDeviceID: "mac-a", displayName: "A", routes: [route],
            instanceTag: "feature-a", customName: nil, customColor: nil,
            customIcon: nil, markActive: true, stackUserID: "user-1",
            teamID: "team-a", now: Date(timeIntervalSince1970: 10)
        )

        #expect(try await store.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        ) == nil)
    }

    @Test func v4RowMigratesToUnknownThenPersistsAuthenticatedTagAcrossRelaunch() async throws {
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
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active
            ) VALUES ('mac-a', 'user-1' || char(31) || 'team-a', 'Studio',
                      'user-1', 'team-a', 1, 2, 1);
            PRAGMA user_version = 4;
        """
        #expect(sqlite3_exec(handle, seed, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let migrated = try MobilePairedMacStore(databaseURL: url)
        let legacy = try #require(await migrated.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        ))
        #expect(legacy.instanceTag == nil)

        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 8443)
        )
        try await migrated.upsert(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [route],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        )

        let reopened = try MobilePairedMacStore(databaseURL: url)
        let authenticated = try #require(await reopened.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        ))
        #expect(authenticated.instanceTag == "feature-b")
        #expect(authenticated.routes == [route])
    }

    private func makeStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            try MobilePairedMacStore(
                databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
            ),
            directory
        )
    }

    private func route(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: port)
        )
    }
}
