#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// What the workspace list shows about the selected SSH computer (PRD D22).
/// Parity with a paired Mac: rows carry their own connection status, the
/// title picker carries the computer's, and an empty list shows only a
/// mode-specific title plus one status line. New workspaces come from `+`;
/// pull-to-refresh reconnects. Value-only; actions are closures.
struct SSHWorkspaceListPanel: Equatable {
    let hostID: UUID
    let status: MobileSSHHostStatus
    let persistence: SSHPersistenceMode?
    let hasWorkspaces: Bool
    /// An idle host the runtime is about to connect on its own; it reads as
    /// connecting rather than flashing "Not connected".
    let willAutoConnect: Bool

    /// The title-picker status line, the same line a paired Mac shows.
    var statusLine: WorkspaceConnectionStatusLine? {
        switch status {
        case .connected: nil
        case .connecting: .reconnecting
        case .idle: willAutoConnect ? .reconnecting : .notConnected
        case .failed: .notConnected
        }
    }

    var emptyTitle: String {
        switch persistence {
        case .tmux:
            L10n.string("mobile.ssh.empty.tmux", defaultValue: "No tmux Sessions")
        case .plain:
            L10n.string("mobile.ssh.empty.plain", defaultValue: "No Shells")
        case .cmuxTUI, .eternalTerminal, .mosh, nil:
            L10n.string("mobile.ssh.empty.cmuxTUI", defaultValue: "No Workspaces")
        }
    }

    /// The single secondary line under an empty list's title; `nil` when
    /// connected (the title alone says it).
    var emptyStatusText: String? {
        switch status {
        case .connected:
            nil
        case .connecting:
            L10n.string("mobile.ssh.status.connecting", defaultValue: "Connecting…")
        case .idle:
            willAutoConnect
                ? L10n.string("mobile.ssh.status.connecting", defaultValue: "Connecting…")
                : L10n.string("mobile.ssh.empty.pullToConnect", defaultValue: "Not connected. Pull down to connect.")
        case .failed(let reason):
            reason
        }
    }
}

struct SSHWorkspaceListPanelActions {
    /// Pull-to-refresh: an explicit connect that also relists workspaces.
    let refresh: @Sendable (UUID) async -> Void
    /// Reconnects an idle host; the runtime ignores it unless eligible.
    let autoConnect: (UUID) -> Void
    /// Relists every connected SSH computer: the list is showing again, and
    /// sessions may have been created or closed while it was hidden.
    let refreshConnected: () -> Void
}

extension View {
    /// Adds the SSH empty state over the workspace list when an SSH computer
    /// is selected, and reconnects it on its own like a Mac. A `nil` panel
    /// leaves the list as is.
    func sshWorkspaceListPanel(_ panel: SSHWorkspaceListPanel?, actions: SSHWorkspaceListPanelActions) -> some View {
        modifier(SSHWorkspaceListPanelModifier(panel: panel, actions: actions))
    }
}

private struct SSHWorkspaceListPanelModifier: ViewModifier {
    let panel: SSHWorkspaceListPanel?
    let actions: SSHWorkspaceListPanelActions
    @Environment(\.scenePhase) private var scenePhase

    /// The host to reconnect: the list is scoped to it, the app is in the
    /// foreground, and it has no live connection. Changes (scoping, return
    /// to foreground, a dropped connection) re-fire the trigger; a failed
    /// host is not idle, so it waits for pull-to-refresh instead of looping.
    private var autoConnectHostID: UUID? {
        guard scenePhase == .active, let panel, panel.status == .idle else { return nil }
        return panel.hostID
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: autoConnectHostID, initial: true) { _, hostID in
                if let hostID { actions.autoConnect(hostID) }
            }
            // Back from a workspace, or back to the foreground: the list may
            // be stale (a session made with `+`, or on a laptop meanwhile).
            .onAppear { actions.refreshConnected() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { actions.refreshConnected() }
            }
            .overlay {
                if let panel, !panel.hasWorkspaces {
                    SSHWorkspaceEmptyState(panel: panel, actions: actions)
                }
            }
    }
}

/// No workspaces on this SSH computer: the plain empty-state title and one
/// status line, in a scroll view so pull-to-refresh works on the empty list
/// exactly as it does on a populated one.
private struct SSHWorkspaceEmptyState: View {
    let panel: SSHWorkspaceListPanel
    let actions: SSHWorkspaceListPanelActions

    var body: some View {
        let hostID = panel.hostID
        let refresh = actions.refresh
        ScrollView {
            ContentUnavailableView {
                Text(panel.emptyTitle)
            } description: {
                if let status = panel.emptyStatusText {
                    Text(status)
                        .accessibilityIdentifier("ssh.empty.status")
                }
            }
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await refresh(hostID) }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("ssh.workspaces.empty")
    }
}
#endif
