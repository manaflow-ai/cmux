import Foundation
import CmuxTerminal

/// Immutable context captured when Ghostty asks cmux to open a terminal link.
struct TerminalLinkOpenRequest: Sendable {
    /// Which browser the caller is asking for.
    enum Destination: Sendable {
        /// Whatever `openTerminalLinksInCmuxBrowser` says. Every click, every
        /// runtime-reported link: the user expressed no preference this time,
        /// so the setting speaks for them.
        case followsSetting
        /// The user picked cmux's browser from a menu. It overrides the
        /// setting and nothing else: a host the embedded browser is not
        /// allowed to load still falls back the way it always does, because
        /// that fallback is not the setting being overridden.
        case cmuxBrowser
        /// The user picked the system default browser from a menu.
        case systemBrowser
    }

    let rawValue: String
    let sourceWorkspaceId: UUID?
    let sourcePanelId: UUID?
    let workingDirectory: String?
    var focus: Bool = true
    /// Whether the remote machine asked for the open without a click on this Mac.
    var isRemoteInitiated: Bool = false
    /// Whether the URL names a file this Mac's terminal wrote, such as a scrollback export.
    var isLocalExport: Bool = false
    var destination: Destination = .followsSetting

    /// Whether Ghostty's action wrote content to a local export file.
    ///
    /// OSC 8 is emitted by terminal output and remains a terminal link, even
    /// though it is a non-unknown Ghostty action kind. Only text and HTML
    /// export actions establish local-file provenance.
    static func isLocalExportActionKind(_ kind: ghostty_action_open_url_kind_e) -> Bool {
        kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT || kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML
    }

}
