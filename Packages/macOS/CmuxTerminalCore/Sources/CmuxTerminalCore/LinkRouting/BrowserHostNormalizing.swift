/// Browser-domain host validation consumed by the terminal link router.
///
/// The terminal must route web links exactly like the embedded browser would
/// accept explicit URL hosts, without importing the browser domain. The app's
/// browser layer conforms and is injected into ``TerminalLinkRouter``.
public protocol BrowserHostNormalizing: Sendable {
    /// Returns the canonical host for raw host text, or `nil` when the text
    /// contains no host the embedded browser could load.
    ///
    /// - Parameter rawHost: The host component extracted from a candidate URL.
    func normalizedHost(_ rawHost: String) -> String?
}
