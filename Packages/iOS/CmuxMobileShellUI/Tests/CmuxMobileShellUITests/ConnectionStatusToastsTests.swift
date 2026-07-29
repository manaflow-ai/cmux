import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import Testing
@testable import CmuxMobileShellUI

@MainActor
struct ConnectionStatusToastsTests {
    @Test func displayStateDerivesInPriorityOrder() {
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: true,
            recoveryFailed: true,
            isRecovering: true,
            connectionState: .connected,
            workspaceStatus: .connected
        ) == .suppressed)
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: true,
            isRecovering: true,
            connectionState: .connected,
            workspaceStatus: .connected
        ) == .lost)
        // A same-client probe recovers while transport and workspace status
        // both stay connected; the recovery flag must still win.
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: true,
            connectionState: .connected,
            workspaceStatus: .connected
        ) == .reconnecting)
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: false,
            connectionState: .disconnected,
            workspaceStatus: .connected
        ) == .unavailable)
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: false,
            connectionState: .connected,
            workspaceStatus: .reconnecting
        ) == .reconnecting)
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: false,
            connectionState: .connected,
            workspaceStatus: .unavailable
        ) == .unavailable)
        #expect(ConnectionStatusDisplayState.derive(
            requiresReauth: false,
            recoveryFailed: false,
            isRecovering: false,
            connectionState: .connected,
            workspaceStatus: .connected
        ) == .connected)
    }

    @Test func sameWorkspaceRecoveryPresentsSuccess() {
        for previous in [ConnectionStatusDisplayState.lost, .reconnecting, .unavailable] {
            #expect(ConnectionStatusToastTransition.decide(
                from: .init(workspaceID: "ws-1", display: previous),
                to: .init(workspaceID: "ws-1", display: .connected)
            ) == .reconnected)
        }
    }

    @Test func steadyConnectionStaysSilent() {
        // Initial mount and flag flips replay an identical snapshot.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .connected),
            to: .init(workspaceID: "ws-1", display: .connected)
        ) == .none)
        // Reauth clearing into a healthy connection is not a recovery.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .suppressed),
            to: .init(workspaceID: "ws-1", display: .connected)
        ) == .none)
    }

    @Test func workspaceSelectionIsNotARecovery() {
        // Selecting a healthy workspace after a disconnected one must not
        // toast success, and must clear the stale capsule whose Reconnect
        // action aims at the previous workspace's Mac.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .unavailable),
            to: .init(workspaceID: "ws-2", display: .connected)
        ) == .dismiss)
        // Selecting a disconnected workspace presents its own status with a
        // fresh reconnect action.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .connected),
            to: .init(workspaceID: "ws-2", display: .unavailable)
        ) == .unavailable)
    }

    @Test func nonConnectedStatesAlwaysPresent() {
        // Identical old/new pairs come from the initial mount and from flag
        // flips; a disconnected snapshot must still surface the capsule.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .unavailable),
            to: .init(workspaceID: "ws-1", display: .unavailable)
        ) == .unavailable)
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .connected),
            to: .init(workspaceID: "ws-1", display: .lost)
        ) == .lost)
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .unavailable),
            to: .init(workspaceID: "ws-1", display: .reconnecting)
        ) == .reconnecting)
        // Reauth clearing while still disconnected re-presents the status
        // the reauth banner had suppressed.
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .suppressed),
            to: .init(workspaceID: "ws-1", display: .unavailable)
        ) == .unavailable)
    }

    @Test func reauthSuppressionClearsTheCapsule() {
        #expect(ConnectionStatusToastTransition.decide(
            from: .init(workspaceID: "ws-1", display: .reconnecting),
            to: .init(workspaceID: "ws-1", display: .suppressed)
        ) == .dismiss)
    }

    @Test func connectionToastFactoriesShareVocabulary() {
        let reconnecting = Toast.connectionReconnecting()
        let unavailable = Toast.connectionUnavailable {}
        let lost = Toast.connectionLost {}
        let reconnected = Toast.connectionReconnected()

        #expect([
            reconnecting.coalescingKey,
            unavailable.coalescingKey,
            lost.coalescingKey,
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
        #expect(reconnected.style == .success)
        #expect(reconnected.autoDismiss == Toast.defaultAutoDismiss(for: .success, hasAction: false))
    }
}
