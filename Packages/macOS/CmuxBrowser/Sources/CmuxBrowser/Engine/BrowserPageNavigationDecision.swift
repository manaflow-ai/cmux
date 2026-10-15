import Foundation

/// What a page does with a navigation it offered to its UI delegate.
public enum BrowserPageNavigationDecision: Equatable, Hashable, Sendable {
    /// Load it.
    case allow
    /// Drop it. The app may have handled it elsewhere (an external app, a new panel).
    case cancel
    /// Save the response as a download instead of rendering it.
    case download
}
