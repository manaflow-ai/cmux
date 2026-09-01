import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior coverage for switches whose caller knows a physical Mac but not
/// which saved app instance owns the row.
@MainActor
@Suite struct DeviceOnlyMacSwitchTests {
    /// A nil-tag switch resolves a single tagged row and dials its route.
    @Test func deviceOnlySwitchResolvesAndDialsTaggedRow() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "feature-a",
            displayName: "Test Mac"
        )
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingPorts: []
        )
        let route = try loopbackRoute(id: "feature-a", port: 51_010)
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [route],
            instanceTag: "feature-a",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )
        let store = makeShell(
            pairedStore: pairedStore,
            factory: factory,
            now: now
        )
        await store.loadPairedMacs()

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(factory.attemptedPorts().first == 51_010)
        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(store.activeMacInstanceTag == "feature-a")
    }

    /// A nil-tag switch chooses the newest tagged row without crossing devices.
    @Test func deviceOnlySwitchUsesMostRecentTaggedRowForOneMac() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "new-build",
            displayName: "Test Mac"
        )
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingPorts: [51_020]
        )
        let oldRoute = try loopbackRoute(id: "old-build", port: 51_020)
        let newRoute = try loopbackRoute(id: "new-build", port: 51_021)
        let otherRoute = try loopbackRoute(id: "other-mac", port: 51_022)
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [oldRoute],
            instanceTag: "old-build",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [newRoute],
            instanceTag: "new-build",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: now.addingTimeInterval(1)
        )
        try await pairedStore.upsert(
            macDeviceID: "other-mac",
            displayName: "Other Mac",
            routes: [otherRoute],
            instanceTag: "other-build",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: now.addingTimeInterval(2)
        )
        let store = makeShell(
            pairedStore: pairedStore,
            factory: factory,
            now: now
        )
        await store.loadPairedMacs()

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        let attempts = factory.attemptedPorts()
        #expect(attempts.first == 51_021)
        #expect(!attempts.contains(51_020))
        #expect(!attempts.contains(51_022))
        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(store.activeMacInstanceTag == "new-build")
    }

    /// A supplied tag selects only its exact saved app-instance row.
    @Test func taggedSwitchStillUsesExactInstanceRow() async throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "new-build",
            displayName: "Test Mac"
        )
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingPorts: [51_030]
        )
        let oldRoute = try loopbackRoute(id: "old-build", port: 51_030)
        let newRoute = try loopbackRoute(id: "new-build", port: 51_031)
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [oldRoute],
            instanceTag: "old-build",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [newRoute],
            instanceTag: "new-build",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now.addingTimeInterval(1)
        )
        let store = makeShell(
            pairedStore: pairedStore,
            factory: factory,
            now: now
        )
        await store.loadPairedMacs()

        #expect(!(await store.switchToMac(
            macDeviceID: "test-mac",
            instanceTag: "old-build"
        )))
        #expect(factory.attemptedPorts().first == 51_030)
        #expect(!factory.attemptedPorts().contains(51_031))
    }

    /// Creates a loopback route for a scripted transport attempt.
    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    /// Creates an isolated SQLite paired-Mac store for one test.
    private func makePairedMacStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    /// Builds a shell wired to the test transport and identity provider.
    private func makeShell(
        pairedStore: MobilePairedMacStore,
        factory: RouteRecordingTransportFactory,
        now: Date
    ) -> MobileShellComposite {
        return MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { now },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "device-only-switch-\(UUID().uuidString)"
            )!,
            multiMacAggregationDefaults: aggregationDefaults(),
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
    }

    /// Disables background secondary dials so switch attempts stay observable.
    private func aggregationDefaults() -> UserDefaults {
        let defaults = UserDefaults(
            suiteName: "device-only-switch-aggregation-\(UUID().uuidString)"
        )!
        defaults.set(false, forKey: "multiMacAggregation")
        return defaults
    }
}
