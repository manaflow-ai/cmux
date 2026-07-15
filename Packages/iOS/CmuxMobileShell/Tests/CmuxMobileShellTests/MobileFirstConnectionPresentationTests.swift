import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileFirstConnectionPresentationTests {
    @Test func manualPairingRequiresAnAuthoritativeEmptyRegistry() {
        #expect(MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: false)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: true,
            registryState: .loaded(hasAccountSession: false)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: true)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loading
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .authRejected
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .unavailable
        ).shouldPresentManualPairing)
    }

    @Test func savedComputerAndHandoffConnectionsShareOneAttemptGate() {
        #expect(MobileFirstConnectionAttemptState(
            connectingSavedComputerID: nil,
            pendingHandoffID: nil
        ).canStartConnection)
        #expect(!MobileFirstConnectionAttemptState(
            connectingSavedComputerID: "mac-a",
            pendingHandoffID: nil
        ).canStartConnection)
        #expect(!MobileFirstConnectionAttemptState(
            connectingSavedComputerID: nil,
            pendingHandoffID: "session-a"
        ).canStartConnection)
    }

    @Test func registryRefreshesBeforeLiveSessionLeaseExpires() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(!MobileFirstConnectionRegistryRefreshPolicy.shouldRefresh(
            lastRefreshAt: now.addingTimeInterval(-89),
            now: now
        ))
        #expect(MobileFirstConnectionRegistryRefreshPolicy.shouldRefresh(
            lastRefreshAt: now.addingTimeInterval(-90),
            now: now
        ))
    }
}
