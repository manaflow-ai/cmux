import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileToast
import SwiftUI

/// Single owner of the connection-status toast capsule.
///
/// Detail views and navigation stacks are ephemeral and can stay retained in
/// parallel (each TabView tab keeps its own stack alive), so per-view
/// presenters race each other with partial knowledge: an update from a hidden
/// workspace can replace the visible toast and aim its Reconnect action at
/// the wrong Mac. This modifier is mounted exactly once, from the
/// always-mounted workspace shell, and derives one display state from the
/// authoritative store signals: recovery flags, transport state, and the
/// selected workspace's Mac status.
struct ConnectionStatusToastPresenter: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    @Environment(ToastCenter.self) private var toasts
    /// True once this session has held a live connection. Startup restoration
    /// commonly passes through disconnected snapshots, so a "Disconnected"
    /// toast before the session ever connected would be a false alarm; the
    /// expected first attach stays silent.
    @State private var hasHeldConnection = false

    func body(content: Content) -> some View {
        let current = snapshot
        content
            .onChange(of: current, initial: true) { previous, current in
                let hadHeldConnection = hasHeldConnection
                if current.display == .connected {
                    hasHeldConnection = true
                }
                guard hadHeldConnection else { return }
                apply(ConnectionStatusToastTransition.decide(from: previous, to: current))
            }
            .onChange(of: toasts.isEnabled) { _, isEnabled in
                // Flag flips don't re-fire the snapshot onChange; re-derive so
                // enabling Toasts mid-disconnect still presents the capsule.
                if isEnabled, hasHeldConnection {
                    apply(ConnectionStatusToastTransition.decide(from: current, to: current))
                }
            }
    }

    private var snapshot: ConnectionStatusSnapshot {
        ConnectionStatusSnapshot(
            workspaceID: store.selectedWorkspaceID,
            display: .derive(
                isSignedIn: store.isSignedIn,
                requiresReauth: store.connectionRequiresReauth,
                recoveryFailed: store.connectionRecoveryFailed,
                isRecovering: store.isRecoveringConnection,
                workspaceStatus: store.selectedWorkspace?.macConnectionStatus
                    ?? store.macConnectionStatus
            )
        )
    }

    private func apply(_ transition: ConnectionStatusToastTransition) {
        guard toasts.isEnabled else { return }
        switch transition {
        case .none:
            break
        case .dismiss:
            toasts.dismiss(coalescingKey: Toast.connectionStatusKey)
        case .unavailable:
            toasts.present(.connectionUnavailable {
                reconnectSelectedWorkspaceMac()
            })
        case .reconnecting:
            toasts.present(.connectionReconnecting())
        case .reconnected:
            toasts.present(.connectionReconnected())
        }
    }

    private func reconnectSelectedWorkspaceMac() {
        let macDeviceID = store.selectedWorkspace?.macDeviceID
        Task {
            if let macDeviceID,
               !macDeviceID.isEmpty,
               await store.switchToMac(macDeviceID: macDeviceID) {
                return
            }
            await store.reconnectOrRefresh()
        }
    }
}

extension View {
    /// Mount exactly once, from the always-mounted workspace shell.
    func connectionStatusToastPresenter(store: CMUXMobileShellStore) -> some View {
        modifier(ConnectionStatusToastPresenter(store: store))
    }
}
