public import Foundation

/// The action a browser surface should take to satisfy a back/forward request
/// while restored session history is active.
///
/// Restored session history is a replay cache: it remembers the back/forward
/// URLs from a prior launch and walks them by issuing fresh navigations, while
/// deferring to WebKit's native back-forward list once the live page accumulates
/// real history. The state machine returns this decision and the surface applies
/// it against its `WKWebView`, so no WebKit object is reached for inside the
/// navigation package.
public enum SessionHistoryTraversalDecision: Sendable, Equatable {
    /// Pop the restored stack and navigate to `url` as a non-typed, history-preserving load.
    case navigate(URL)

    /// Defer to WebKit's native `goBack()`.
    case nativeGoBack

    /// Defer to WebKit's native `goForward()`.
    case nativeGoForward

    /// No traversal is possible; the caller should only refresh availability.
    case refreshOnly
}
