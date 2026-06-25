/// The localized button labels a ``CloseConfirmationAlertPresenter`` stamps onto
/// the confirmation `NSAlert`.
///
/// **Why these arrive resolved.** `String(localized:)` must resolve in the app
/// bundle (the package bundle lacks the keys), so the app-side caller resolves
/// the "Close" / "Cancel" / "Don't ask again" labels and hands them to the
/// presenter through this `Sendable` value. The presenter performs only the
/// AppKit button-wiring; it never localizes. Mirrors the same app-side-strings
/// discipline as ``CmuxWorkspaces/CloseConfirmationPrompt``.
public struct CloseConfirmationButtonStrings: Sendable, Equatable {
    /// The confirm (first / default) button title (legacy
    /// `dialog.closeTab.close`, "Close").
    public let close: String
    /// The cancel (second) button title (legacy `dialog.closeTab.cancel`,
    /// "Cancel").
    public let cancel: String
    /// The "Don't ask again" suppression checkbox title (legacy
    /// `dialog.dontAskAgain`). Only used when the prompt shows the checkbox.
    public let dontAskAgain: String

    /// Creates a resolved set of confirmation button labels.
    public init(close: String, cancel: String, dontAskAgain: String) {
        self.close = close
        self.cancel = cancel
        self.dontAskAgain = dontAskAgain
    }
}
