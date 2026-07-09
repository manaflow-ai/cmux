import CmuxSettings
import Foundation

/// Per-workspace orchestrator for closing one pane of a mirrored multi-pane tmux
/// window (the pane-header ✕).
///
/// kill-pane is destructive and the mirror pane has no local child process for
/// the normal needs-confirm check, so this coordinator owns the close-time
/// confirmation flow: it consults the close-tab warning settings, runs a LIVE
/// pane-activity query (the subscription cache lags ~1s, which would let a
/// just-started command slip through), falls back to the cached classification
/// when the link is down, and asks the workspace to present the modal only when
/// confirmation is required. The pane is removed by the resulting
/// `%layout-change` (or `%window-close` for the window's last pane), never
/// locally.
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: the lifted
/// `Workspace.requestRemoteTmuxPaneClose(windowMirror:tmuxPaneId:)` was a plain
/// method on the `@MainActor` `Workspace` class. The window-mirror command
/// surface (``RemoteTmuxMirrorPaneCloseControlling``) and the workspace seam
/// (``RemoteTmuxMirrorHosting``) are both `@MainActor`. The in-flight guard set
/// (`pendingRemoteTmuxPaneCloseIds`) lives here so click spam cannot double-kill
/// or stack dialogs.
///
/// The host reference is weak (the workspace owns the coordinator), so there is
/// no retain cycle.
@MainActor
public final class RemoteTmuxMirrorCoordinator<Host: RemoteTmuxMirrorHosting> {
    private weak var host: Host?

    /// tmux pane ids (multi-pane mirror ✕) with a close-time activity query or
    /// confirmation in flight, so click spam can't double-kill or stack dialogs.
    private var pendingRemoteTmuxPaneCloseIds: Set<Int> = []

    /// Creates a pane-close coordinator. Call ``attach(host:)`` at the
    /// composition point before any close runs so the modal-confirmation forward
    /// resolves.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    /// Closes one pane of a mirrored multi-pane tmux window, confirming first
    /// when that pane is running an active foreground command. Faithful lift of
    /// `Workspace.requestRemoteTmuxPaneClose(windowMirror:tmuxPaneId:)`.
    public func requestRemoteTmuxPaneClose(
        windowMirror: any RemoteTmuxMirrorPaneCloseControlling,
        tmuxPaneId: Int
    ) {
        // Close warnings disabled → even an active command wouldn't confirm;
        // kill with no added round trip.
        guard CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: true, source: .tabCloseButton
        ) else {
            windowMirror.requestKillPane(tmuxPaneId)
            return
        }
        guard !pendingRemoteTmuxPaneCloseIds.contains(tmuxPaneId) else { return }
        pendingRemoteTmuxPaneCloseIds.insert(tmuxPaneId)
        windowMirror.queryPaneActivity(tmuxPaneId) { [weak self, weak windowMirror] states in
            // Hop off the control-stream dispatch before a (modal) dialog can
            // block it; the defer keeps the in-flight guard balanced on every path.
            Task { @MainActor [weak self, weak windowMirror] in
                guard let self else { return }
                defer { self.pendingRemoteTmuxPaneCloseIds.remove(tmuxPaneId) }
                guard let windowMirror else { return }
                let state = states?[tmuxPaneId] ?? windowMirror.paneForegroundState(tmuxPaneId)
                if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                    requiresConfirmation: state?.hasActiveCommand ?? false,
                    source: .tabCloseButton
                ) {
                    // No way to ask → refuse the destructive kill rather than
                    // falling through to an unconfirmed one (only reachable in
                    // teardown states where the pane header shouldn't be clickable).
                    let activeCommand: String?
                    if let command = state?.command, state?.hasActiveCommand == true, !command.isEmpty {
                        activeCommand = command
                    } else {
                        activeCommand = nil
                    }
                    guard let host = self.host,
                          host.presentRemoteTmuxPaneCloseConfirmation(activeCommand: activeCommand) else {
                        return
                    }
                }
                windowMirror.requestKillPane(tmuxPaneId)
            }
        }
    }
}
