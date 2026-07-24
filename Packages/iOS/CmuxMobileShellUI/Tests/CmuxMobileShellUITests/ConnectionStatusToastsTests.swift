import CmuxMobileSupport
import CmuxMobileToast
import Testing
@testable import CmuxMobileShellUI

@MainActor
struct ConnectionStatusToastsTests {
    @Test func recoveryPhaseDerivesInPriorityOrder() {
        #expect(ConnectionRecoveryToastPhase.derive(
            requiresReauth: true,
            recoveryFailed: true,
            isRecovering: true,
            connectionError: "Account mismatch"
        ) == .reauth(message: "Account mismatch"))
        #expect(ConnectionRecoveryToastPhase.derive(
            requiresReauth: false,
            recoveryFailed: true,
            isRecovering: true,
            connectionError: "Ignored"
        ) == .lost)
        #expect(ConnectionRecoveryToastPhase.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: true,
            connectionError: nil
        ) == .recovering)
        #expect(ConnectionRecoveryToastPhase.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: false,
            connectionError: nil
        ) == .idle)
    }

    @Test func connectionToastFactoriesShareVocabulary() {
        let reconnecting = Toast.connectionReconnecting()
        let unavailable = Toast.connectionUnavailable {}
        let lost = Toast.connectionLost {}
        let reauth = Toast.connectionReauthRequired(message: nil, signOut: {})
        let reconnected = Toast.connectionReconnected()

        #expect([
            reconnecting.coalescingKey,
            unavailable.coalescingKey,
            lost.coalescingKey,
            reauth.coalescingKey,
            reconnected.coalescingKey,
        ].allSatisfy { $0 == Toast.connectionStatusKey })
        #expect(reconnecting.style == .info)
        #expect(reconnecting.systemImage == "arrow.triangle.2.circlepath")
        #expect(reconnecting.autoDismiss == Toast.defaultAutoDismiss(for: .info, hasAction: false))
        #expect(unavailable.style == .failure)
        #expect(unavailable.action?.label == L10n.string(
            "mobile.workspace.reconnect",
            defaultValue: "Reconnect"
        ))
        #expect(lost.style == .failure)
        #expect(lost.action?.label == L10n.string(
            "mobile.recovery.retry",
            defaultValue: "Retry"
        ))
        #expect(reauth.style == .failure)
        #expect(reauth.action?.label == L10n.string(
            "mobile.recovery.switchAccount",
            defaultValue: "Sign Out & Switch Account"
        ))
        #expect(reauth.autoDismiss == .never)
        #expect(reconnected.style == .success)
        #expect(reconnected.autoDismiss == Toast.defaultAutoDismiss(for: .success, hasAction: false))
    }

    @Test func reauthWithoutSignOutHasNoAction() {
        let reauth = Toast.connectionReauthRequired(message: "Authorization failed", signOut: nil)

        #expect(reauth.message == "Authorization failed")
        #expect(reauth.action == nil)
        #expect(reauth.autoDismiss == .never)
    }
}
