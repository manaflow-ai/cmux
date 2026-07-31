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
        // The recovery flags describe the foreground RPC connection; a
        // selected workspace on a healthy secondary Mac must not read as
        // recovering (or falsely toast "Reconnected") while the foreground
        // connection cycles.
        let usesForegroundConnection = store.selectedWorkspaceUsesForegroundConnection
        return ConnectionStatusSnapshot(
            workspaceID: store.selectedWorkspaceID,
            display: .derive(
                isSignedIn: store.isSignedIn,
                requiresReauth: store.connectionRequiresReauth,
                recoveryFailed: usesForegroundConnection && store.connectionRecoveryFailed,
                isRecovering: usesForegroundConnection && store.isRecoveringConnection,
                // Explicit selection only: `selectedWorkspace` falls back to
                // `workspaces.first`, which would attribute status to an
                // arbitrary row after the selection is cleared. Without an
                // explicit selection follow the list policy rather than the
                // raw foreground status: hidden-computers-only deliberately
                // reads .connected so no toast advertises a Reconnect that
                // cannot reach any visible Mac.
                workspaceStatus: store.explicitlySelectedWorkspace?.macConnectionStatus
                    ?? store.workspaceListConnectionStatus
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
        let explicitSelection = store.explicitlySelectedWorkspace
        Task {
            if let explicitSelection {
                await store.reconnectToMac(
                    macDeviceID: explicitSelection.macDeviceID,
                    instanceTag: explicitSelection.macInstanceTag
                )
            } else {
                // No explicit selection: the capsule showed the aggregate
                // list status, so the action follows the list recovery
                // policy, which fails closed when several candidate Macs
                // could be dialed.
                await store.reconnectOrRefresh()
            }
        }
    }
}

extension View {
    /// Mount exactly once, from the always-mounted workspace shell.
    func connectionStatusToastPresenter(store: CMUXMobileShellStore) -> some View {
        modifier(ConnectionStatusToastPresenter(store: store))
    }
}
