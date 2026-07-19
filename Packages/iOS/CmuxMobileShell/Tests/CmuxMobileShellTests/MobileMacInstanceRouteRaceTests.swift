import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileMacInstanceRouteRaceTests {
    @Test func delayedRegistryAResultCannotOverwriteSameDeviceAfterBCommit() async throws {
        let routeA = try route(id: "a", port: 51_001)
        let staleA = try route(id: "stale-a", port: 52_001)
        let routeB = try route(id: "b", port: 51_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(route: routeA, tag: "feature-a")]],
            blockedTeams: []
        )
        let registry = GatedInstanceRouteRegistry(routes: [staleA])
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await shell.loadPairedMacs()
        let cachedA = try #require(shell.pairedMacs.first)
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        shell.refreshRoutesFromRegistryForTesting(for: cachedA, scope: scope)
        await registry.waitUntilStarted()
        try await pairedStore.upsert(
            macDeviceID: "shared-mac",
            displayName: "Studio",
            routes: [routeB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )
        await registry.release()
        await shell.registryRouteRefreshTask?.value

        let current = try #require(await pairedStore.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).first(where: { $0.macDeviceID == "shared-mac" }))
        #expect(current.instanceTag == "feature-b")
        #expect(current.routes == [routeB])
    }

    @Test func cachedPresenceACannotOverwriteStoreAfterBCommit() async throws {
        let routeA = try route(id: "a", port: 51_001)
        let pushedA = try route(id: "pushed-a", port: 52_001)
        let routeB = try route(id: "b", port: 51_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(route: routeA, tag: "feature-a")]],
            blockedTeams: []
        )
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await shell.loadPairedMacs()
        try await pairedStore.upsert(
            macDeviceID: "shared-mac",
            displayName: "Studio",
            routes: [routeB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 20)
        )
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        shell.applyPresenceUpdate(.online(PresenceInstance(
            deviceId: "shared-mac",
            tag: "feature-a",
            platform: "mac",
            online: true,
            lastSeenAt: 1_000,
            routes: [pushedA]
        )), scope: scope)
        await shell.pushedRouteSyncTask?.value

        let current = try #require(await pairedStore.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).first(where: { $0.macDeviceID == "shared-mac" }))
        #expect(current.instanceTag == "feature-b")
        #expect(current.routes == [routeB])
    }

    private func pairedMac(route: CmxAttachRoute, tag: String) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: "shared-mac",
            displayName: "Studio",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: tag
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

private actor GatedInstanceRouteRegistry: DeviceRegistryRefreshing {
    private let routes: [CmxAttachRoute]
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(routes: [CmxAttachRoute]) {
        self.routes = routes
    }

    func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return routes
    }

    func listDevices() async -> DeviceRegistryListOutcome { .transientFailure }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
