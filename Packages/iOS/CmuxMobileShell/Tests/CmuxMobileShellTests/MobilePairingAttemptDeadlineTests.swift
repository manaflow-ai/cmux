import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingAttemptDeadlineTests {
    @Test func qrPairingURLTimesOutWithoutWaitingForStuckTransport() async throws {
        let store = makeStore()
        let startedAt = Date()

        let result = await store.connectPairingURLResult(Self.qrURL)

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
        #expect(Date().timeIntervalSince(startedAt) < 0.05)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: Self.qrURL)
        let startedAt = Date()

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
        #expect(Date().timeIntervalSince(startedAt) < 0.05)
    }

    private static let qrURL = "cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465"

    private func makeStore(pairingCode: String = "") -> MobileShellComposite {
        MobileShellComposite(
            runtime: PairingDeadlineRuntime(),
            isSignedIn: true,
            pairingCode: pairingCode,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!
        )
    }
}
