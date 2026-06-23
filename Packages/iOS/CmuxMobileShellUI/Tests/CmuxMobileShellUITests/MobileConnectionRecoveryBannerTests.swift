import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileConnectionRecoveryBannerTests {
    @Test func cachedWorkspaceReconnectShowsReconnectBanner() {
        #expect(MobileConnectionRecoveryBanner.presentation(
            requiresReauth: false,
            connectionError: nil,
            recoveryFailed: false,
            isRecoveringConnection: false,
            preservesWorkspaceShellDuringReconnect: true
        ) == .reconnecting)
    }

    @Test func activeRecoveryShowsReconnectBanner() {
        #expect(MobileConnectionRecoveryBanner.presentation(
            requiresReauth: false,
            connectionError: nil,
            recoveryFailed: false,
            isRecoveringConnection: true,
            preservesWorkspaceShellDuringReconnect: false
        ) == .reconnecting)
    }

    @Test func failureAndReauthOverrideReconnectBanner() {
        #expect(MobileConnectionRecoveryBanner.presentation(
            requiresReauth: false,
            connectionError: nil,
            recoveryFailed: true,
            isRecoveringConnection: true,
            preservesWorkspaceShellDuringReconnect: true
        ) == .lost)

        #expect(MobileConnectionRecoveryBanner.presentation(
            requiresReauth: true,
            connectionError: "Wrong account",
            recoveryFailed: true,
            isRecoveringConnection: true,
            preservesWorkspaceShellDuringReconnect: true
        ) == .reauth("Wrong account"))
    }
}
