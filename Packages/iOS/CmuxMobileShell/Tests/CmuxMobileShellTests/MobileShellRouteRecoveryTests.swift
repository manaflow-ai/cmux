import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Test func failedReplacementSubscriptionEscalatesToLatestStoredRoute() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setHostIdentity(deviceID: nil, instanceTag: nil)
    let box = TransportBox()
    let factory = RouteRecordingTransportFactory(
        router: router,
        box: box,
        failingPorts: []
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pairedStore = try MobilePairedMacStore(
        databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
    )
    let staleRoute = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 51_000)
    )
    let freshRoute = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 51_001)
    )
    try await pairedStore.upsert(
        macDeviceID: "test-mac",
        displayName: "Test Mac",
        routes: [freshRoute],
        markActive: true,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now
    )
    let runtime = LivenessTestRuntime(
        transportFactory: factory,
        now: { clock.now },
        supportedRouteKinds: [.debugLoopback]
    )
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        connectionState: .connected,
        pairedMacStore: pairedStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        reachability: AlwaysOnlineReachability(),
        pairingHintDefaults: UserDefaults(
            suiteName: "route-recovery-\(UUID().uuidString)"
        )!
    )
    let staleTicket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [staleRoute],
        expiresAt: clock.now.addingTimeInterval(3_600)
    )
    store.activeTicket = staleTicket
    store.activeRoute = staleRoute
    store.activeMacInstanceTag = "default"
    store.foregroundMacDeviceID = "test-mac"
    store.lastReconnectStackUserID = "user-1"
    store.replaceRemoteClient(with: MobileCoreRPCClient(
        runtime: runtime,
        route: staleRoute,
        ticket: staleTicket,
        allowsStackAuthFallback: true
    ))
    let replacementSubscribe = 1
    await router.holdSubscribeRequest(number: replacementSubscribe)
    store.recoverMobileConnection(trigger: .manual)
    #expect(await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: replacementSubscribe
    ))
    await box.get()?.close()

    let escalated = try await pollUntil(attempts: 600) {
        factory.attemptedPorts().contains(51_001)
            && store.macConnectionStatus == .connected
            && store.recoveryID == nil
    }
    #expect(escalated, "failed replacement subscription must refresh the stored route")

    let retryRoute = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 51_002)
    )
    try await pairedStore.upsert(
        macDeviceID: "test-mac",
        displayName: "Test Mac",
        routes: [retryRoute],
        markActive: true,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now.addingTimeInterval(1)
    )
    store.markMacConnectionUnavailable()
    store.retryMobileConnection()

    let retriedStoredRoute = try await pollUntil(attempts: 600) {
        factory.attemptedPorts().contains(51_002)
            && store.macConnectionStatus == .connected
            && store.recoveryID == nil
    }
    #expect(retriedStoredRoute, "Retry from unavailable must refresh the stored route")
    #expect(factory.attemptedPorts().contains(51_001))
    #expect(factory.attemptedPorts().contains(51_002))
}
