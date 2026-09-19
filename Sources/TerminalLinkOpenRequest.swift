import Foundation

/// Immutable context captured when Ghostty asks cmux to open a terminal link.
struct TerminalLinkOpenRequest: Sendable {
    let rawValue: String
    let sourceWorkspaceId: UUID?
    let sourcePanelId: UUID?
    let workingDirectory: String?
    /// Whether an embedded browser pane should receive focus after opening.
    let focus: Bool

    init(
        rawValue: String,
        sourceWorkspaceId: UUID?,
        sourcePanelId: UUID?,
        workingDirectory: String?,
        focus: Bool = true
    ) {
        self.rawValue = rawValue
        self.sourceWorkspaceId = sourceWorkspaceId
        self.sourcePanelId = sourcePanelId
        self.workingDirectory = workingDirectory
        self.focus = focus
    }
}
