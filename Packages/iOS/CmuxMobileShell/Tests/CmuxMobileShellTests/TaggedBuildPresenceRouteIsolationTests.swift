import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite struct TaggedBuildPresenceRouteIsolationTests {
    @Test func tagBRestartCannotRewriteTagARoutesOnTheSameMac() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let routeA = try route(id: "a", host: "100.64.0.1", port: 51_001)
        let routeB = try route(id: "b", host: "100.64.0.2", port: 51_002)
        let restartedB = try route(id: "b-restart", host: "100.64.0.3", port: 52_002)
        let restartedA = try route(id: "a-restart", host: "100.64.0.4", port: 52_001)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(routes: [original])]],
            blockedTeams: []
        )
        let buildScope = try #require(MobileIOSBuildScope("feature-a"))
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            iosBuildScope: buildScope,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.registryDevices = [RegistryDevice(
            deviceId: "shared-physical-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 1),
            instances: [
                RegistryAppInstance(
                    tag: "feature-a",
                    routes: [original],
                    lastSeenAt: Date(timeIntervalSince1970: 1)
                ),
                RegistryAppInstance(
                    tag: "feature-b",
                    routes: [original],
                    lastSeenAt: Date(timeIntervalSince1970: 1)
                ),
            ]
        )]
        let accountScope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        store.applyPresenceUpdate(
            snapshot([
                instance(tag: "feature-a", routes: [routeA]),
                instance(tag: "feature-b", routes: [routeB]),
            ]),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value
        #expect(await pairedStore.currentUpsertCount() == 1)
        #expect(try await storedRoutes(in: pairedStore) == [routeA])
        let featureARoutes = store.registryDevices.first?.instances
            .first(where: { $0.tag == "feature-a" })?.routes
        let featureBRoutes = store.registryDevices.first?.instances
            .first(where: { $0.tag == "feature-b" })?.routes
        #expect(featureARoutes == [routeA])
        #expect(featureBRoutes == [routeB])

        store.applyPresenceUpdate(
            .offline(instance(tag: "feature-a", online: false, routes: [routeA]), reason: .goodbye),
            scope: accountScope
        )
        store.applyPresenceUpdate(
            .online(instance(tag: "feature-b", routes: [restartedB])),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value
        #expect(await pairedStore.currentUpsertCount() == 1)
        #expect(try await storedRoutes(in: pairedStore) == [routeA])
        let restartedBRoutes = store.registryDevices.first?.instances
            .first(where: { $0.tag == "feature-b" })?.routes
        #expect(restartedBRoutes == [restartedB])

        store.applyPresenceUpdate(
            .online(instance(tag: "feature-a", routes: [restartedA])),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value
        #expect(await pairedStore.currentUpsertCount() == 2)
        #expect(try await storedRoutes(in: pairedStore) == [restartedA])
    }

    @Test func unscopedBuildUsesOnlyTheSoleRouteAdvertisingInstance() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let routeA = try route(id: "a", host: "100.64.0.1", port: 51_001)
        let routeB = try route(id: "b", host: "100.64.0.2", port: 51_002)
        let restartedB = try route(id: "b-restart", host: "100.64.0.3", port: 52_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(routes: [original])]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        let accountScope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        store.applyPresenceUpdate(
            snapshot([
                instance(tag: "feature-a", routes: [routeA]),
                instance(tag: "feature-b", routes: [routeB]),
            ]),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value
        #expect(await pairedStore.currentUpsertCount() == 0)
        #expect(try await storedRoutes(in: pairedStore) == [original])

        store.applyPresenceUpdate(
            .offline(instance(tag: "feature-a", online: false, routes: [routeA]), reason: .goodbye),
            scope: accountScope
        )
        store.applyPresenceUpdate(
            .online(instance(tag: "feature-b", routes: [restartedB])),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value
        #expect(await pairedStore.currentUpsertCount() == 1)
        #expect(try await storedRoutes(in: pairedStore) == [restartedB])
    }

    @Test func explicitEmptyRoutesClearRegistryWithoutErasingPersistedRoutes() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let advertised = try route(id: "advertised", host: "100.64.0.2", port: 51_001)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(routes: [original])]],
            blockedTeams: []
        )
        let buildScope = try #require(MobileIOSBuildScope("feature-a"))
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            iosBuildScope: buildScope,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        store.registryDevices = [RegistryDevice(
            deviceId: "registry-only-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 1),
            instances: [RegistryAppInstance(
                tag: "feature-a",
                routes: [advertised],
                lastSeenAt: Date(timeIntervalSince1970: 1)
            )]
        )]
        let accountScope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        store.applyPresenceUpdate(
            .routes(instance(deviceId: "registry-only-mac", tag: "feature-a", routes: [])),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value

        #expect(store.registryDevices.first?.instances.first?.routes.isEmpty == true)
        #expect(await pairedStore.currentUpsertCount() == 0)
        #expect(try await storedRoutes(in: pairedStore) == [original])
    }

    @Test func unscopedMultiTagPresenceStillTriggersLastKnownGoodRecovery() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let routeA = try route(id: "a", host: "100.64.0.1", port: 51_001)
        let routeB = try route(id: "b", host: "100.64.0.2", port: 51_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(routes: [original], isActive: true)]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability()
        )
        await store.loadPairedMacs()
        let accountScope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        store.applyPresenceUpdate(
            snapshot([
                instance(tag: "feature-a", routes: [routeA]),
                instance(tag: "feature-b", routes: [routeB]),
            ]),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value

        let recoveryRan = try await pollUntil(attempts: 50) {
            store.connectionRecoveryFailed
        }
        #expect(recoveryRan)
        #expect(await pairedStore.currentUpsertCount() == 0)
        #expect(try await storedRoutes(in: pairedStore) == [original])
    }

    private func route(id: String, host: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    private func pairedMac(routes: [CmxAttachRoute], isActive: Bool = false) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: "shared-physical-mac",
            displayName: "Studio",
            routes: routes,
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }

    private func instance(
        deviceId: String = "shared-physical-mac",
        tag: String,
        online: Bool = true,
        routes: [CmxAttachRoute]
    ) -> PresenceInstance {
        PresenceInstance(
            deviceId: deviceId,
            tag: tag,
            platform: "mac",
            online: online,
            lastSeenAt: 1_000,
            routes: routes
        )
    }

    private func snapshot(_ instances: [PresenceInstance]) -> PresenceUpdate {
        .snapshot(PresenceSnapshot(
            teamId: "team-a",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: [PresenceDevice(
                deviceId: "shared-physical-mac",
                platform: "mac",
                online: true,
                lastSeenAt: 1_000,
                instances: instances
            )]
        ))
    }

    private func storedRoutes(in store: DelayedTeamPairedMacStore) async throws -> [CmxAttachRoute]? {
        try await store.loadAll(stackUserID: "user-1", teamID: "team-a").first?.routes
    }
}
