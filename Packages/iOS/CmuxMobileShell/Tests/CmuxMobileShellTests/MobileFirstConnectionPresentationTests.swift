import Testing
@testable import CmuxMobileShell

@Suite struct MobileFirstConnectionPresentationTests {
    @Test func manualPairingRequiresNoSavedComputerAndNoAccountSession() {
        #expect(MobileFirstConnectionState(
            hasSavedComputer: false,
            hasAccountSession: false
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: true,
            hasAccountSession: false
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            hasAccountSession: true
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: true,
            hasAccountSession: true
        ).shouldPresentManualPairing)
    }
}
