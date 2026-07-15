import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func reconnectActiveMacUsesPersistedIrohBeforeNetworkFallback() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
        #expect(await router.workspaceIDs(for: "workspace.list") == [nil])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["live-workspace"])
    }

    @Test func rejectedIrohReconnectNeverDowngradesToRawTailscale() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box, failingKinds: [.iroh])
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(store.connectionState == .disconnected)
        #expect(factory.attemptedKinds() == [.iroh])
    }

    @Test func legacyMacWithoutIrohFailsClosedInsteadOfSendingBearerOverTCP() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
    }

    @Test func reconnectUsesSingleRegistrySnapshotToRescueNonActiveMacWithNoLocalRoutes() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "stable", displayName: "Mac B")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let good = try registryIroh(
            id: "iroh-b",
            endpointID: String(repeating: "b", count: 64)
        )
        let wrong = try registryIroh(
            id: "iroh-wrong",
            endpointID: String(repeating: "c", count: 64)
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "mac-b",
                platform: "mac",
                displayName: "Mac B",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(tag: "other", routes: [wrong], lastSeenAt: clock.now),
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [good, try tailscale(51_002)],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [try tailscale(51_001)],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        try await pairedStore.upsert(
            macDeviceID: "mac-b",
            displayName: "Mac B",
            routes: [],
            instanceTag: "stable",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.foregroundMacDeviceID == "mac-b")
        #expect(store.activeRoute?.id == "iroh-b")
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        let rows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.count == 2)
        let upgraded = try #require(rows.first { $0.macDeviceID == "mac-b" })
        #expect(upgraded.instanceTag == "stable")
        #expect(upgraded.routes.contains { $0.id == "iroh-b" })
    }

    @Test func switchToLegacySavedMacUpgradesFromRegistryWithoutRescan() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "stable")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let iroh = try registryIroh(
            id: "iroh-stable",
            endpointID: String(repeating: "d", count: 64)
        )
        let legacy = try tailscale(51_003)
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([
            RegistryDevice(
                deviceId: "test-mac",
                platform: "mac",
                displayName: "Test Mac",
                lastSeenAt: clock.now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [iroh, legacy],
                        lastSeenAt: clock.now
                    ),
                ]
            ),
        ]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let before = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        #expect(store.activeRoute?.id == iroh.id)
        #expect(!store.connectionRequiresReauth)
        let after = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        #expect(after.createdAt == before.createdAt)
        #expect(after.isActive)
        #expect(after.routes.contains { $0.id == iroh.id })
    }

    @Test func legacySavedMacWithoutPublishedIrohIsRetainedAndRequestsMacUpdate() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let registry = SnapshotCountingDeviceRegistry(outcome: .ok([]))
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try tailscale(51_004)
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [legacy],
            instanceTag: "stable",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let before = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        let store = await makeMigrationShell(
            pairedStore: pairedStore,
            registry: registry,
            runtime: runtime
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!store.connectionRequiresReauth)
        #expect(store.hasKnownPairedMac)
        #expect(await registry.counts() == .init(list: 1, fresh: 0))
        let copy = [store.connectionError, store.connectionErrorGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        #expect(copy.contains("update cmux"))
        #expect(copy.contains("mac"))
        #expect(copy.contains("automatically"))
        let after = try #require(await pairedStore.activeMac(stackUserID: "user-1", teamID: nil))
        #expect(after.macDeviceID == before.macDeviceID)
        #expect(after.routes == before.routes)
        #expect(after.createdAt == before.createdAt)
        #expect(after.isActive)
    }

    @Test func switchingToIrohCapableMacUsesPinnedIrohRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func foregroundResumeRedialsDeadIrohSessionBeforeUserAction() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            )
        )
        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstTransport = try #require(box.get())
        await firstTransport.close()

        store.suspendForegroundRefresh()
        clock.advance(by: 61)
        store.resumeForegroundRefresh()

        let recovered = try await pollUntil(attempts: 100) {
            guard let current = box.get() else { return false }
            let foregroundProbeCount = await router.count(of: "mobile.workspace.list")
            return current !== firstTransport
                && store.connectionState == .connected
                && foregroundProbeCount >= 1
        }
        #expect(recovered)
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func storedReconnectPinsIrohAndExcludesRawFallbacks() throws {
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try loopback(), try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale, .debugLoopback],
            preferNonLoopback: true
        )

        #expect(routes.map(\.kind) == [.iroh])
        guard case let .peer(identity, hints) = routes[0].endpoint else {
            Issue.record("Expected pinned Iroh route")
            return
        }
        #expect(identity.endpointID == String(repeating: "a", count: 64))
        #expect(hints.count == 1)
        #expect(hints[0].value == "100.82.214.112:50906")
        #expect(hints[0].source == .tailscale)
        #expect(hints[0].use == .fallbackOnly)
    }

    private func registryIroh(id: String, endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: endpointID),
                pathHints: []
            ),
            priority: -10_000
        )
    }

    private func makeMigrationShell(
        pairedStore: MobilePairedMacStore,
        registry: any DeviceRegistryRefreshing,
        runtime: any MobileSyncRuntime
    ) async -> MobileShellComposite {
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "iroh-migration-\(UUID().uuidString)")!
        )
        await store.loadPairedMacs()
        return store
    }
}

private actor SnapshotCountingDeviceRegistry: DeviceRegistryRefreshing {
    struct Counts: Equatable, Sendable {
        let list: Int
        let fresh: Int
    }

    private let outcome: DeviceRegistryListOutcome
    private var listCalls = 0
    private var freshCalls = 0

    init(outcome: DeviceRegistryListOutcome) {
        self.outcome = outcome
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) async -> [CmxAttachRoute]? {
        freshCalls += 1
        return nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        listCalls += 1
        return outcome
    }

    func counts() -> Counts {
        Counts(list: listCalls, fresh: freshCalls)
    }
}
