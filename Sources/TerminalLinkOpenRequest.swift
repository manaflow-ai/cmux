import Foundation

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
}
