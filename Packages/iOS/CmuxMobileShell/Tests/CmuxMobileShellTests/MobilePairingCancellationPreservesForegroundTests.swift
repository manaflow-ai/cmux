import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingCancellationPreservesForegroundTests {
    @Test func cancelInFlightPairingKeepsExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport)
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-cancel-\(UUID().uuidString)")!
        )
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        let pairing = Task { @MainActor in
            await store.connectPairingURLResult("cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465")
        }
        let started = try await pollUntil {
            await transport.connectCount() == 1
        }
        #expect(started)
        store.cancelPairing()
        await transport.releaseStuckConnects()
        _ = await pairing.value

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
    }
}
