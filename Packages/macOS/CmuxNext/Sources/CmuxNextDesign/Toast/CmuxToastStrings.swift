import Foundation

/// The words toasts share; callers pass their own messages.
public nonisolated struct CmuxToastStrings {
    public nonisolated init() {}
    public static var undo: String { String(localized: "toast.undo", defaultValue: "Undo", bundle: .module) }
    public static var reopen: String { String(localized: "toast.reopen", defaultValue: "Reopen", bundle: .module) }
    /// The close button's VoiceOver label.
    public static var dismiss: String { String(localized: "toast.dismiss", defaultValue: "Dismiss", bundle: .module) }
}
