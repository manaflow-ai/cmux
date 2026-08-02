import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

@Suite
struct MobilePairedMacDeviceIDCanonicalizationTests {
    private let canonicalDeviceID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let mixedCaseDeviceID = "Aaaaaaaa-BbBb-4cCc-8dDd-EeEeEeEeEeEe"

    @Test
    func migratesV6UUIDCaseDuplicatesWithoutRetainingStaleRouteAuthority() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("paired-macs.sqlite3")
        let staleIrohRoute = try CmxAttachRoute(
            id: "stale-iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            ),
            priority: -10_000
        )
        let freshRoute = try route(id: "fresh", host: "100.64.0.2", port: 52_002)
        let otherTeamRoute = try route(id: "other-team", host: "100.64.0.3", port: 52_003)

        try seedV6Database(
            at: databaseURL,
            staleIrohRoute: staleIrohRoute,
            freshRoute: freshRoute,
            otherTeamRoute: otherTeamRoute
        )

        let store = try MobilePairedMacStore(databaseURL: databaseURL)
        let teamA = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
        let canonical = try #require(teamA.first { $0.macDeviceID == canonicalDeviceID })

        #expect(teamA.count == 3)
        #expect(teamA.filter { $0.macDeviceID == canonicalDeviceID }.count == 1)
        #expect(canonical.displayName == "Fresh lowercase")
        #expect(canonical.customName == "Fresh custom")
        #expect(canonical.customColor == "palette:7")
        #expect(canonical.customIcon == "desktopcomputer")
        #expect(canonical.createdAt == Date(timeIntervalSince1970: 10))
        #expect(canonical.lastSeenAt == Date(timeIntervalSince1970: 30))
        #expect(canonical.isActive)
        #expect(canonical.routes == [freshRoute])
        #expect(!canonical.routes.contains { $0.id == staleIrohRoute.id })

        let opaqueIDs = Set(teamA.map(\.macDeviceID)).intersection(["Opaque-Mac-ID", "opaque-mac-id"])
        #expect(opaqueIDs == ["Opaque-Mac-ID", "opaque-mac-id"])

        let teamB = try await store.loadAll(stackUserID: "user-1", teamID: "team-b")
        let scopedCopy = try #require(teamB.first)
        #expect(teamB.count == 1)
        #expect(scopedCopy.macDeviceID == canonicalDeviceID)
        #expect(scopedCopy.displayName == "Other team")
        #expect(scopedCopy.routes == [otherTeamRoute])
    }

    @Test
    func canonicalizesUUIDsAcrossProductionMutationsWhilePreservingOpaqueIDs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let initialRoute = try route(id: "initial", host: "100.64.0.10", port: 52_010)
        let restoredRoute = try route(id: "restored", host: "100.64.0.11", port: 52_011)
        let authorizedRoute = try route(id: "authorized", host: "100.64.0.12", port: 52_012)

        try await store.upsert(
            macDeviceID: mixedCaseDeviceID,
            displayName: "Initial",
            routes: [initialRoute],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(try await store.upsertIfNewer(
            macDeviceID: canonicalDeviceID,
            displayName: "Restored",
            routes: [restoredRoute],
            instanceTag: "stable",
            customName: "Restored custom",
            customColor: nil,
            customIcon: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        ))
        #expect(try await store.upsertRoutesIfAuthorized(
            macDeviceID: mixedCaseDeviceID,
            displayName: "Authorized",
            routes: [authorizedRoute],
            condition: .matchingInstanceTag("stable"),
            markActive: nil,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        ))
        try await store.setCustomization(
            macDeviceID: mixedCaseDeviceID,
            customName: "Customized",
            customColor: "palette:2",
            customIcon: "laptopcomputer",
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 4)
        )
        try await store.upsert(
            macDeviceID: "other-mac",
            displayName: "Other",
            routes: [initialRoute],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 5)
        )
        try await store.setActive(
            macDeviceID: mixedCaseDeviceID,
            stackUserID: "user-1",
            teamID: "team-a"
        )

        let canonicalRows = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
            .filter { $0.macDeviceID == canonicalDeviceID }
        let canonical = try #require(canonicalRows.first)
        #expect(canonicalRows.count == 1)
        #expect(canonical.displayName == "Authorized")
        #expect(canonical.customName == "Customized")
        #expect(canonical.customColor == "palette:2")
        #expect(canonical.customIcon == "laptopcomputer")
        #expect(canonical.createdAt == Date(timeIntervalSince1970: 1))
        #expect(canonical.lastSeenAt == Date(timeIntervalSince1970: 4))
        #expect(canonical.routes == [authorizedRoute])
        #expect(canonical.isActive)

        try await store.upsert(
            macDeviceID: "Opaque-Mac-ID",
            displayName: nil,
            routes: [],
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 6)
        )
        try await store.upsert(
            macDeviceID: "opaque-mac-id",
            displayName: nil,
            routes: [],
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 7)
        )
        let opaqueIDs = Set(try await store.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).map(\.macDeviceID)).intersection(["Opaque-Mac-ID", "opaque-mac-id"])
        #expect(opaqueIDs == ["Opaque-Mac-ID", "opaque-mac-id"])

        try await store.remove(
            macDeviceID: mixedCaseDeviceID,
            instanceTag: "stable",
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
            .allSatisfy { $0.macDeviceID != canonicalDeviceID })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func route(id: String, host: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    private func seedV6Database(
        at databaseURL: URL,
        staleIrohRoute: CmxAttachRoute,
        freshRoute: CmxAttachRoute,
        otherTeamRoute: CmxAttachRoute
    ) throws {
        let teamAOwnerKey = "user-1\u{1F}team-a\u{1F}stable"
        let teamBOwnerKey = "user-1\u{1F}team-b\u{1F}stable"
        let staleRouteJSON = try encodedRoute(staleIrohRoute)
        let freshRouteJSON = try encodedRoute(freshRoute)
        let otherTeamRouteJSON = try encodedRoute(otherTeamRoute)
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

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
                instance_tag TEXT,
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
            INSERT INTO paired_macs VALUES (
                \(sqlQuoted(mixedCaseDeviceID)), \(sqlQuoted(teamAOwnerKey)),
                'Stale mixed case', 'user-1', 'team-a', 10, 20, 0,
                'Stale custom', 'palette:1', 'desktopcomputer.fill', 'stable'
            );
            INSERT INTO paired_macs VALUES (
                \(sqlQuoted(canonicalDeviceID)), \(sqlQuoted(teamAOwnerKey)),
                'Fresh lowercase', 'user-1', 'team-a', 15, 30, 1,
                'Fresh custom', 'palette:7', 'desktopcomputer', 'stable'
            );
            INSERT INTO paired_macs VALUES (
                \(sqlQuoted(mixedCaseDeviceID.uppercased())), \(sqlQuoted(teamBOwnerKey)),
                'Other team', 'user-1', 'team-b', 5, 50, 1,
                NULL, NULL, NULL, 'stable'
            );
            INSERT INTO paired_macs VALUES (
                'Opaque-Mac-ID', \(sqlQuoted(teamAOwnerKey)), NULL,
                'user-1', 'team-a', 40, 40, 0, NULL, NULL, NULL, 'stable'
            );
            INSERT INTO paired_macs VALUES (
                'opaque-mac-id', \(sqlQuoted(teamAOwnerKey)), NULL,
                'user-1', 'team-a', 41, 41, 0, NULL, NULL, NULL, 'stable'
            );
            INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
            VALUES (
                \(sqlQuoted(mixedCaseDeviceID)), \(sqlQuoted(teamAOwnerKey)),
                'stale-iroh', 'iroh', \(sqlQuoted(staleRouteJSON)), -10000
            );
            INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
            VALUES (
                \(sqlQuoted(canonicalDeviceID)), \(sqlQuoted(teamAOwnerKey)),
                'fresh', 'tailscale', \(sqlQuoted(freshRouteJSON)), 0
            );
            INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
            VALUES (
                \(sqlQuoted(mixedCaseDeviceID.uppercased())), \(sqlQuoted(teamBOwnerKey)),
                'other-team', 'tailscale', \(sqlQuoted(otherTeamRouteJSON)), 0
            );
            PRAGMA user_version = 6;
        """
        let result = sqlite3_exec(database, seed, nil, nil, nil)
        #expect(result == SQLITE_OK)
    }

    private func encodedRoute(_ route: CmxAttachRoute) throws -> String {
        let data = try JSONEncoder().encode(route)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func sqlQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
