public import Foundation

/// The prompt last submitted inside one panel, shown per surface in the
/// sidebar.
///
/// The workspace keeps one of these per panel id so a workspace running several
/// agents can report which surface is waiting, instead of collapsing every
/// panel into the single workspace-level `latestSubmittedMessage`.
public struct SidebarPanelPromptState: Equatable, Sendable {
    /// The submitted prompt preview.
    public let message: String
    /// When it was submitted.
    public let submittedAt: Date

    /// Creates a panel prompt state.
    public init(message: String, submittedAt: Date) {
        self.message = message
        self.submittedAt = submittedAt
    }
}
