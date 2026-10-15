import Foundation

/// How the app handled a ``BrowserPageOpenRequest``.
public enum BrowserPageOpenDisposition: Equatable, Hashable, Sendable {
    /// The app opened the URL in a new panel itself; the engine creates nothing.
    case handled
    /// The engine opens the page as a popup it owns (keeps `window.opener`).
    case allowPopup
    /// Block it.
    case block
}
