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
}
