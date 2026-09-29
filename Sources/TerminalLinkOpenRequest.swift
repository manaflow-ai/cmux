import Foundation
import CmuxTerminal

/// Immutable context captured when Ghostty asks cmux to open a terminal link.
struct TerminalLinkOpenRequest: Sendable {
    let rawValue: String
    let sourceWorkspaceId: UUID?
    let sourcePanelId: UUID?
    let workingDirectory: String?
    var focus: Bool = true
    /// Whether the remote machine asked for the open without a click on this Mac.
    var isRemoteInitiated: Bool = false
    /// Whether the URL names a file this Mac's terminal wrote, such as a scrollback export.
    var isLocalExport: Bool = false

    /// Whether Ghostty's action wrote content to a local export file.
    ///
    /// OSC 8 is emitted by terminal output and remains a terminal link, even
    /// though it is a non-unknown Ghostty action kind. Only text and HTML
    /// export actions establish local-file provenance.
    static func isLocalExportActionKind(_ kind: ghostty_action_open_url_kind_e) -> Bool {
        kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT || kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML
    }
}
