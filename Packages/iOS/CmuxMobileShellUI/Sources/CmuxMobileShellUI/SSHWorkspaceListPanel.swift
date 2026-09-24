#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// What the workspace list shows about the selected SSH computer (PRD D22):
/// its connection state and, while it has no workspaces, how to start one.
/// Value-only; actions are closures.
struct SSHWorkspaceListPanel: Equatable {
    let hostID: UUID
    let hostName: String
    let status: MobileSSHHostStatus
    let persistence: SSHPersistenceMode?
    let hasWorkspaces: Bool
}

struct SSHWorkspaceListPanelActions {
    let retry: (UUID) -> Void
    let newSession: (UUID) -> Void
}

extension View {
    /// Adds the SSH status banner and empty state over the workspace list
    /// when an SSH computer is selected. A `nil` panel leaves the list as is.
    func sshWorkspaceListPanel(_ panel: SSHWorkspaceListPanel?, actions: SSHWorkspaceListPanelActions) -> some View {
        modifier(SSHWorkspaceListPanelModifier(panel: panel, actions: actions))
    }
}

private struct SSHWorkspaceListPanelModifier: ViewModifier {
    let panel: SSHWorkspaceListPanel?
    let actions: SSHWorkspaceListPanelActions

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let panel, panel.hasWorkspaces, panel.status != .connected, panel.status != .idle {
                    SSHWorkspaceStatusBanner(panel: panel, actions: actions)
                }
            }
            .overlay {
                if let panel, !panel.hasWorkspaces {
                    SSHWorkspaceEmptyState(panel: panel, actions: actions)
                }
            }
    }
}

/// A slim banner for a connecting or failed SSH computer whose workspaces
/// are already listed, so rows stay visible (Mail-style status).
private struct SSHWorkspaceStatusBanner: View {
    let panel: SSHWorkspaceListPanel
    let actions: SSHWorkspaceListPanelActions

    var body: some View {
        HStack(spacing: 12) {
            SSHStatusLabel(status: panel.status)
            Spacer(minLength: 8)
            if panel.status.isFailed {
                Button(SSHCopy.retry) { actions.retry(panel.hostID) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("ssh.workspaces.retry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("ssh.workspaces.status")
    }
}

/// No workspaces yet on this SSH computer: its state plus New Session, or
/// the failure with Retry.
private struct SSHWorkspaceEmptyState: View {
    let panel: SSHWorkspaceListPanel
    let actions: SSHWorkspaceListPanelActions

    var body: some View {
        ContentUnavailableView {
            Label(panel.hostName, systemImage: "terminal")
        } description: {
            VStack(spacing: 8) {
                SSHStatusLabel(status: panel.status)
                Text(message)
            }
        } actions: {
            switch panel.status {
            case .failed:
                Button(SSHCopy.retry) { actions.retry(panel.hostID) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ssh.workspaces.retry")
            case .connecting:
                EmptyView()
            case .idle:
                Button(L10n.string("mobile.ssh.workspaces.connect", defaultValue: "Connect")) {
                    actions.retry(panel.hostID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ssh.workspaces.connect")
            case .connected:
                Button(L10n.string("mobile.ssh.workspaces.newSession", defaultValue: "New Session")) {
                    actions.newSession(panel.hostID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ssh.workspaces.newSession")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("ssh.workspaces.empty")
    }

    private var message: String {
        switch panel.status {
        case .failed:
            L10n.string(
                "mobile.ssh.workspaces.failed",
                defaultValue: "cmux couldn't reach this computer. Check that it's on, that this iPhone can reach its address, and that its SSH server accepts this key."
            )
        case .connecting:
            L10n.string("mobile.ssh.workspaces.connecting", defaultValue: "Connecting to this computer…")
        case .idle:
            L10n.string("mobile.ssh.workspaces.idle", defaultValue: "Connect to see this computer's sessions.")
        case .connected:
            switch panel.persistence {
            case .plain:
                L10n.string(
                    "mobile.ssh.workspaces.empty.plain",
                    defaultValue: "No sessions yet. Plain shells end when you leave the app."
                )
            default:
                L10n.string(
                    "mobile.ssh.workspaces.empty",
                    defaultValue: "No sessions yet. Start one to open a terminal on this computer."
                )
            }
        }
    }
}
#endif
