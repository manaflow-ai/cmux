import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct ReconnectInstanceSwitchRollbackTests {
    @Test func failedSameDeviceTagSwitchRestoresLiveInstanceRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac", instanceTag: "feature-a", displayName: "Test Mac"
        )
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingPorts: [51000]
        )
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let routeA = try loopbackRoute(id: "live-a", port: 51001)
        let staleRouteB = try loopbackRoute(id: "stale-b", port: 51000)
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [staleRouteB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        )
        let ticketA = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [routeA],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let liveClientA = MobileCoreRPCClient(
            runtime: runtime,
            route: routeA,
            ticket: ticketA,
            allowsStackAuthFallback: true
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "same-device-tag-rollback-\(UUID().uuidString)"
            )!
        )
        store.activeTicket = ticketA
        store.activeRoute = routeA
        store.activeMacInstanceTag = "feature-a"
        store.foregroundMacDeviceID = "test-mac"
        store.replaceRemoteClient(with: liveClientA)
        await store.loadPairedMacs()

        let switched = await store.switchToMac(macDeviceID: "test-mac")

        #expect(!switched)
        #expect(store.connectionState == .connected)
        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(store.activeMacInstanceTag == "feature-a")
        #expect(factory.attemptedPorts().contains(51000))
        let restored = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: nil
        ))
        #expect(restored.instanceTag == "feature-a")
        #expect(restored.routes.first?.endpoint == routeA.endpoint)
        #expect(!restored.routes.contains(where: { $0.endpoint == staleRouteB.endpoint }))
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    private func makePairedMacStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }
}
