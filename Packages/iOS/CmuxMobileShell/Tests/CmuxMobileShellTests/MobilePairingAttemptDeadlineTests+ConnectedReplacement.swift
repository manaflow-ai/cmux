import Testing
@testable import CmuxMobileShell

@MainActor
extension MobilePairingAttemptDeadlineTests {
    @Test func failedPairingWhileConnectedReportsAttemptedRoute() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let runtime = PairingDeadlineRuntime()
        let store = makeStore(runtime: runtime, connectionState: .connected)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)

        let result = await store.connectPairingURLResult(try Self.pairingURL())

        #expect(result == .failed)
        #expect(store.connectionState == .connected)
        #expect(store.connectionError?.contains("127.0.0.1") == true)
    }

    @Test func authFailureDuringPairingWhileConnectedKeepsExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let runtime = PairingDeadlineRuntime(
            transportFactory: AuthorizationFailingTransportFactory()
        )
        let store = makeStore(runtime: runtime, connectionState: .connected)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        let result = await store.connectPairingURLResult(try Self.pairingURL())

        #expect(result == .failed)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionRequiresReauth == false)
        #expect(store.connectionError?.isEmpty == false)
    }

    @Test func successfulPairingWhileConnectedStartsReplacementEventStream() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1)
        let initialSubscribeCount = await router.count(of: "mobile.events.subscribe")
        let ticket = try makeTicket(clock: clock)

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .connected)
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: initialSubscribeCount + 1)
    }
}
