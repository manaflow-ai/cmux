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
        let policy = MobileFirstConnectionRegistryRefreshPolicy()

        #expect(!policy.shouldRefresh(
            lastRefreshAt: now.addingTimeInterval(-39),
            now: now
        ))
        #expect(policy.shouldRefresh(
            lastRefreshAt: now.addingTimeInterval(-40),
            now: now
        ))
    }

    @Test func discoveredSessionDismissesOnlyAutomaticPairing() {
        var automatic = MobileAddDevicePresentationState()
        automatic.present(origin: .automaticFirstConnection)
        automatic.dismissAutomaticForAvailableSession()
        #expect(!automatic.isPresented)

        var userInitiated = MobileAddDevicePresentationState()
        userInitiated.present(origin: .userInitiated)
        userInitiated.dismissAutomaticForAvailableSession()
        #expect(userInitiated.isPresented)

        var attachApproval = MobileAddDevicePresentationState()
        attachApproval.present(origin: .attachTicketApproval)
        attachApproval.dismissAutomaticForAvailableSession()
        #expect(attachApproval.isPresented)
    }
}
