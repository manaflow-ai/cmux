internal import CmuxMobileSupport
import Foundation

/// Localized strings the SSH runtime writes into terminals and statuses.
enum L10nSSH {
    static var sessionEnded: String {
        L10n.string("mobile.ssh.session.ended", defaultValue: "Session ended. Type to start a new one.")
    }
    static var authFailed: String {
        L10n.string("mobile.ssh.error.authFailed", defaultValue: "The server did not accept this key.")
    }
    static var hostKeyRejected: String {
        L10n.string("mobile.ssh.error.hostKeyRejected", defaultValue: "Connection cancelled: server identity not trusted.")
    }
    static var connectionRefused: String {
        L10n.string(
            "mobile.ssh.error.connectionRefused",
            defaultValue: "This computer refused the connection. Check the port and that SSH is turned on."
        )
    }
    static var connectTimedOut: String {
        L10n.string("mobile.ssh.error.connectTimedOut", defaultValue: "This computer didn't respond. Check the address and your network.")
    }
    static var hostNotFound: String {
        L10n.string("mobile.ssh.error.hostNotFound", defaultValue: "No computer was found at this address.")
    }
    static var unreachable: String {
        L10n.string("mobile.ssh.error.unreachable", defaultValue: "Couldn't reach this computer. Check the address and your network.")
    }
    static var noKey: String {
        L10n.string("mobile.ssh.error.noKey", defaultValue: "Choose a key for this computer first.")
    }
    static var tmuxMissing: String {
        L10n.string("mobile.ssh.error.tmuxMissing", defaultValue: "tmux is not installed on this computer.")
    }
    static var installingCmuxTUI: String {
        L10n.string("mobile.ssh.cmuxtui.installing", defaultValue: "Installing cmux-tui on this computer…")
    }
    static var browserUntitled: String {
        L10n.string("mobile.ssh.browser.untitled", defaultValue: "Browser")
    }
    static var browserFailed: String {
        L10n.string("mobile.ssh.browser.failed", defaultValue: "Browser unavailable")
    }
    static func cmuxTUIUnsupported(os: String, arch: String) -> String {
        L10n.string(
            "mobile.ssh.error.cmuxTUIUnsupported",
            defaultValue: "cmux-tui doesn't run on this computer (\(os) \(arch))."
        )
    }
    static var cmuxTUIMissing: String {
        L10n.string("mobile.ssh.error.cmuxTUIMissing", defaultValue: "cmux-tui is not installed on this computer.")
    }
    static var cmuxTUISessionGone: String {
        L10n.string("mobile.ssh.error.cmuxTUISessionGone", defaultValue: "This cmux-tui session is no longer running.")
    }

    /// The row subtitle naming a workspace's kind (PRD D31).
    static func kindLabel(_ kind: MobileSSHWorkspaceKind, cmuxTUISession: String? = nil) -> String {
        switch kind {
        case .tmux:
            return L10n.string("mobile.ssh.kind.tmux", defaultValue: "tmux session")
        case .shell:
            return L10n.string("mobile.ssh.kind.shell", defaultValue: "Shell")
        case .cmuxTUI:
            // Workspaces from another cmux-tui session (a laptop's) name it,
            // so same-named workspaces from two sessions stay apart.
            if let session = cmuxTUISession, session != MobileSSHCmuxTUIProvider.sessionName {
                return L10n.string("mobile.ssh.kind.cmuxTUI.session", defaultValue: "cmux-tui · \(session)")
            }
            return L10n.string("mobile.ssh.kind.cmuxTUI", defaultValue: "cmux-tui")
        }
    }
}
