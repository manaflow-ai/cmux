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
            recordsByTeam: ["team-a": [pairedMac(routes: [original], instanceTag: "feature-a")]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
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

    @Test func officialBuildUsesStableMacForRoutesAndRecovery() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let defaultRoute = try route(id: "stable", host: "100.64.0.2", port: 51_001)
        let routeB = try route(id: "b", host: "100.64.0.3", port: 51_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(
                routes: [original],
                isActive: true,
                instanceTag: "default"
            )]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            buildCompatibilityPolicy: .official,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability()
        )
        await store.loadPairedMacs()
        store.registryDevices = [RegistryDevice(
            deviceId: "shared-physical-mac",
            platform: "mac",
            displayName: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 1),
            instances: [
                RegistryAppInstance(
                    tag: "default",
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
                instance(tag: "default", routes: [defaultRoute]),
                instance(tag: "feature-b", routes: [routeB]),
            ]),
            scope: accountScope
        )
        await store.pushedRouteSyncTask?.value

        #expect(try await storedInstanceTag(in: pairedStore) == "default")
        #expect(await pairedStore.currentUpsertCount() == 1)
        #expect(try await storedRoutes(in: pairedStore) == [defaultRoute])
        let recoveryRan = try await pollUntil(attempts: 50) {
            store.isRecoveringConnection || store.connectionRecoveryFailed
        }
        #expect(recoveryRan)
    }

    @Test func explicitEmptyRoutesClearRegistryWithoutErasingPersistedRoutes() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let advertised = try route(id: "advertised", host: "100.64.0.2", port: 51_001)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(routes: [original], instanceTag: "feature-a")]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
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

    @Test func legacyMacWithAmbiguousMultiTagPresenceDoesNotTriggerRecovery() async throws {
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

        #expect(!store.connectionRecoveryFailed)
        #expect(await pairedStore.currentUpsertCount() == 0)
        #expect(try await storedRoutes(in: pairedStore) == [original])
    }

    @Test func twoPairedMacsUseTheirOwnAuthenticatedTags() async throws {
        let originalA = try route(id: "original-a", host: "100.64.0.1", port: 50_001)
        let originalB = try route(id: "original-b", host: "100.64.0.2", port: 50_002)
        let updatedA = try route(id: "updated-a", host: "100.64.0.3", port: 51_001)
        let updatedB = try route(id: "updated-b", host: "100.64.0.4", port: 51_002)
        let noiseA = try route(id: "noise-a", host: "100.64.0.5", port: 52_001)
        let noiseB = try route(id: "noise-b", host: "100.64.0.6", port: 52_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [
                pairedMac(deviceID: "mac-a", routes: [originalA], instanceTag: "feature-a"),
                pairedMac(deviceID: "mac-b", routes: [originalB], instanceTag: "default"),
            ]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)

        store.applyPresenceUpdate(.snapshot(PresenceSnapshot(
            teamId: "team-a",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: [
                presenceDevice(id: "mac-a", instances: [
                    instance(deviceId: "mac-a", tag: "feature-a", routes: [updatedA]),
                    instance(deviceId: "mac-a", tag: "default", routes: [noiseA]),
                ]),
                presenceDevice(id: "mac-b", instances: [
                    instance(deviceId: "mac-b", tag: "default", routes: [updatedB]),
                    instance(deviceId: "mac-b", tag: "feature-a", routes: [noiseB]),
                ]),
            ]
        )), scope: scope)
        await store.pushedRouteSyncTask?.value

        let stored = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(stored.first { $0.macDeviceID == "mac-a" }?.routes == [updatedA])
        #expect(stored.first { $0.macDeviceID == "mac-a" }?.instanceTag == "feature-a")
        #expect(stored.first { $0.macDeviceID == "mac-b" }?.routes == [updatedB])
        #expect(stored.first { $0.macDeviceID == "mac-b" }?.instanceTag == "default")
    }

    @Test func snapshotIndexesPairedMacsBeforeScanningManyInstances() async throws {
        let original = try route(id: "original", host: "100.64.0.1", port: 50_000)
        let updated = try route(id: "updated", host: "100.64.0.2", port: 51_000)
        let noise = try route(id: "noise", host: "100.64.0.3", port: 52_000)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(
                deviceID: "paired-mac",
                routes: [original],
                instanceTag: "feature-a"
            )]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        await pairedStore.resetLoadAllCount()
        let noiseDevices = (0..<200).map { index in
            let id = "unpaired-\(index)"
            return presenceDevice(id: id, instances: [
                instance(deviceId: id, tag: "feature-a", routes: [noise]),
            ])
        }
        let pairedDevice = presenceDevice(id: "paired-mac", instances: [
            instance(deviceId: "paired-mac", tag: "feature-a", routes: [updated]),
        ])
        let scope = MobileShellScopeSnapshot(
            userID: "user-1", teamID: "team-a", generation: 0
        )

        store.applyPresenceUpdate(.snapshot(PresenceSnapshot(
            teamId: "team-a",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: noiseDevices + [pairedDevice]
        )), scope: scope)
        await store.pushedRouteSyncTask?.value

        #expect(await pairedStore.currentUpsertCount() == 1)
        #expect(await pairedStore.currentLoadAllCount() == 2)
        #expect(try await storedRoutes(in: pairedStore) == [updated])
    }

    @Test func presenceUsesPairedMacAddedAfterTheDisplayCacheLoaded() async throws {
        let originalA = try route(id: "original-a", host: "100.64.0.1", port: 50_001)
        let originalB = try route(id: "original-b", host: "100.64.0.2", port: 50_002)
        let updatedB = try route(id: "updated-b", host: "100.64.0.3", port: 51_002)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["team-a": [pairedMac(
                deviceID: "mac-a",
                routes: [originalA],
                instanceTag: "feature-a"
            )]],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" }
        )
        await store.loadPairedMacs()
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Studio B",
            routes: [originalB],
            instanceTag: "feature-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        )
        let upsertsBeforePresence = await pairedStore.currentUpsertCount()
        await pairedStore.resetLoadAllCount()
        let scope = MobileShellScopeSnapshot(
            userID: "user-1", teamID: "team-a", generation: 0
        )

        store.applyPresenceUpdate(.snapshot(PresenceSnapshot(
            teamId: "team-a",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: [presenceDevice(id: "mac-b", instances: [
                instance(deviceId: "mac-b", tag: "feature-b", routes: [updatedB]),
            ])]
        )), scope: scope)
        await store.pushedRouteSyncTask?.value

        #expect(await pairedStore.currentUpsertCount() == upsertsBeforePresence + 1)
        #expect(await pairedStore.currentLoadAllCount() == 2)
        let stored = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(stored.first { $0.macDeviceID == "mac-b" }?.routes == [updatedB])
    }

    private func route(id: String, host: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    private func pairedMac(
        deviceID: String = "shared-physical-mac",
        routes: [CmxAttachRoute],
        isActive: Bool = false,
        instanceTag: String? = nil
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: deviceID,
            displayName: "Studio",
            routes: routes,
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: instanceTag
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

    private func presenceDevice(id: String, instances: [PresenceInstance]) -> PresenceDevice {
        PresenceDevice(
            deviceId: id,
            platform: "mac",
            online: true,
            lastSeenAt: 1_000,
            instances: instances
        )
    }

    private func storedRoutes(in store: DelayedTeamPairedMacStore) async throws -> [CmxAttachRoute]? {
        try await store.loadAll(stackUserID: "user-1", teamID: "team-a").first?.routes
    }

    private func storedInstanceTag(in store: DelayedTeamPairedMacStore) async throws -> String? {
        try await store.loadAll(stackUserID: "user-1", teamID: "team-a").first?.instanceTag
    }
}
