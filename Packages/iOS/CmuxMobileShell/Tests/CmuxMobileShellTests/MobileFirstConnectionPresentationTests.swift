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
}
