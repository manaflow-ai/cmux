import Foundation

/// The words toasts share; callers pass their own messages.
public nonisolated struct CmuxToastStrings {
    public nonisolated init() {}
    public static var undo: String { String(localized: "toast.undo", defaultValue: "Undo", bundle: .l10n) }
    public static var reopen: String { String(localized: "toast.reopen", defaultValue: "Reopen", bundle: .l10n) }
    /// The key that runs an Undo toast's action, shown in its tooltip (a key glyph, not words).
    public static let undoShortcut = "⌘Z"
    /// A Details button's title while the details show: the same button hides them.
    public static var hideDetails: String {
        String(localized: "toast.hideDetails", defaultValue: "Hide Details", bundle: .l10n)
    }
    /// The button that hides every toast of a kind for good (``CmuxToast/offersNeverShow``).
    public static var dontShowAgain: String {
        String(localized: "toast.dontShowAgain", defaultValue: "Don’t Show Again", bundle: .l10n)
    }
    /// The close button's VoiceOver label.
    public static var dismiss: String { String(localized: "toast.dismiss", defaultValue: "Dismiss", bundle: .l10n) }
}
