import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacRouteAuthorityTests {
    @Test func tagBCannotBeOverwrittenByTagARoutes() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let routeA = try route(id: "a", port: 51_001)
        let routeB = try route(id: "b", port: 51_002)
        let timestampB = Date(timeIntervalSince1970: 20)
        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Studio B",
            routes: [routeB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: timestampB
        )

        let wrote = try await store.upsertRoutesIfAuthorized(
            macDeviceID: "shared-mac",
            displayName: "Stale A",
            routes: [routeA],
            condition: .matchingInstanceTag("feature-a"),
            markActive: nil,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )

        #expect(!wrote)
        let current = try #require(await store.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).first)
        #expect(current.displayName == "Studio B")
        #expect(current.routes == [routeB])
        #expect(current.instanceTag == "feature-b")
        #expect(current.lastSeenAt == timestampB)
        #expect(current.isActive)
    }

    @Test func unclaimedWriteCreatesLegacyRowButRejectsClaimedRow() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyRoute = try route(id: "legacy", port: 51_001)
        let claimedRoute = try route(id: "claimed", port: 51_002)

        let created = try await store.upsertRoutesIfAuthorized(
            macDeviceID: "shared-mac",
            displayName: "Legacy",
            routes: [legacyRoute],
            condition: .unclaimed,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(created)
        #expect(try await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        )?.routes == [legacyRoute])

        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Claimed",
            routes: [claimedRoute],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )
        let rejected = try await store.upsertRoutesIfAuthorized(
            macDeviceID: "shared-mac",
            displayName: "Stale legacy",
            routes: [legacyRoute],
            condition: .unclaimed,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )

        #expect(!rejected)
        let current = try #require(await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        ))
        #expect(current.displayName == "Claimed")
        #expect(current.routes == [claimedRoute])
        #expect(current.instanceTag == "feature-b")
    }

    @Test func emptyTagRestoreCannotCreateLegacySibling() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taggedRoute = try route(id: "tagged", port: 51_003)
        let staleRoute = try route(id: "stale", port: 51_004)
        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Stable",
            routes: [taggedRoute],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )

        let wrote = try await store.upsertIfNewer(
            macDeviceID: "shared-mac",
            displayName: "Legacy restore",
            routes: [staleRoute],
            instanceTag: "   ",
            customName: nil,
            customColor: nil,
            customIcon: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(!wrote)
        let rows = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.count == 1)
        #expect(rows.first?.instanceTag == "stable")
    }

    @Test func explicitPairingAuthorizationReinstatesDeletedTailscaleRoute() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletedRoute = try route(id: "deleted", port: 51_005)
        let retainedRoute = try route(id: "retained", port: 51_006)
        let scope = MobilePairedMacRouteWriteCondition.matchingInstanceTag("default")
        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Desk Mac",
            routes: [deletedRoute, retainedRoute],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(try await store.removeRouteIfAuthorized(
            macDeviceID: "shared-mac",
            route: deletedRoute,
            condition: scope,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        ))

        // A successful scan first persists the newly advertised route, then
        // records that the user explicitly authorized its exact destination.
        // Passive advertisement alone must remain unable to undo a deletion.
        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Desk Mac",
            routes: [deletedRoute, retainedRoute],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )
        #expect(try await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        )?.routes == [retainedRoute])

        try await store.authorizeUserTailscaleRoutes(
            macDeviceID: "shared-mac",
            instanceTag: "default",
            stackUserID: "user-1",
            teamID: "team-a",
            routes: [deletedRoute]
        )

        #expect(try await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        )?.routes.map(\.id).sorted() == ["deleted", "retained"])
    }

    @Test func routeRemovalRejectsStaleIdForDifferentEndpoint() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let routeA = try route(id: "shared-id", port: 51_007)
        let routeB = try route(id: "other-id", port: 51_008)
        try await store.upsert(
            macDeviceID: "shared-mac",
            displayName: "Desk Mac",
            routes: [routeA, routeB],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 10)
        )

        // The stale record reuses routeB's id while still naming routeA's
        // endpoint. Removal must follow the endpoint, never the stale id.
        let staleRoute = try CmxAttachRoute(
            id: routeB.id,
            kind: routeA.kind,
            endpoint: routeA.endpoint
        )
        #expect(try await store.removeRouteIfAuthorized(
            macDeviceID: "shared-mac",
            route: staleRoute,
            condition: .matchingInstanceTag("default"),
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        ))
        #expect(try await store.activeMac(
            stackUserID: "user-1",
            teamID: "team-a"
        )?.routes == [routeB])
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
