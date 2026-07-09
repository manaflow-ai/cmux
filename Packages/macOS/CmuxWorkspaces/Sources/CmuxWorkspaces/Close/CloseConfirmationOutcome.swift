/// The result of presenting a ``CloseConfirmationPrompt``: whether the user
/// confirmed the close, and (for the anchor-close dialog) whether they checked
/// the "Don't ask again" suppression box. The ``WorkspaceCloseCoordinator``
/// reads `confirmed` to gate the close and `suppressionChecked` to persist the
/// `workspaceGroups.anchorCloseSuppressed` flag, exactly as the legacy
/// `confirmAnchorWorkspaceClose` body did.
public struct CloseConfirmationOutcome: Sendable, Equatable {
    /// Whether the user chose the confirm (Close) button (legacy
    /// `runCloseConfirmationAlert(...) == .alertFirstButtonReturn`).
    public let confirmed: Bool
    /// Whether the suppression checkbox was checked on confirm. Always `false`
    /// for prompts without a checkbox (`showsSuppressionCheckbox == false`).
    public let suppressionChecked: Bool

    /// Creates a confirmation outcome.
    public init(confirmed: Bool, suppressionChecked: Bool) {
        self.confirmed = confirmed
        self.suppressionChecked = suppressionChecked
    }
}
