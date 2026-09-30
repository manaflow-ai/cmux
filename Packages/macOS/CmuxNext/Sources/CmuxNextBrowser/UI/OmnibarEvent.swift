public import Foundation

/// Why the omnibar stopped editing.
public enum OmnibarEndReason: Equatable, Sendable {
    /// Enter, a suggestion click, or Paste and Go: the page loads `url`.
    case commit(URL)
    /// Escape with nothing left to revert.
    case cancel
    /// Focus moved elsewhere (click, Tab, another pane).
    case blur
}

/// Editing boundaries the App routes (focus handoff between the omnibar and
/// the page belongs to the App's focus owner, not to this view).
public enum OmnibarEvent: Equatable, Sendable {
    case didBeginEditing
    case didEndEditing(OmnibarEndReason)
}
