public import Foundation

/// Browser-domain URL validation consumed by the terminal link router.
///
/// The terminal must route web links exactly like the embedded browser would
/// accept navigable URL text, without importing the browser domain. The app's
/// browser layer conforms and is injected into ``TerminalLinkRouter``.
public protocol BrowserHostNormalizing: Sendable {
    /// Returns the canonical host for raw host text, or `nil` when the text
    /// contains no host the embedded browser could load.
    ///
    /// - Parameter rawHost: The host component extracted from a candidate URL.
    func normalizedHost(_ rawHost: String) -> String?

    /// Resolves raw text the same way the browser address field would.
    ///
    /// - Parameter input: The candidate URL text from the terminal.
    func navigableWebURL(_ input: String) -> URL?
}
