public import Foundation

/// Browser-domain host validation consumed by the terminal link router.
///
/// The terminal must route web links exactly like the embedded browser would
/// accept them, without importing the browser domain. The app's browser layer
/// conforms and is injected into ``TerminalLinkRouter``.
public protocol BrowserHostNormalizing: Sendable {
    /// Returns the canonical host for raw host text, or `nil` when the text
    /// contains no host the embedded browser could load.
    ///
    /// - Parameter rawHost: The host component extracted from a candidate URL.
    func normalizedHost(_ rawHost: String) -> String?

    /// Resolves free-form terminal text (bare domains, `localhost:port`,
    /// scheme-less hosts) into a browser-navigable web URL, or `nil` when the
    /// text is not navigable.
    ///
    /// - Parameter input: The raw link text.
    func navigableWebURL(_ input: String) -> URL?

    /// Whether `label` (`com`, `md`, `dev`) is a public top-level domain, so
    /// scheme-less terminal text under it can be a web host rather than a
    /// folder name such as `build-fleet`.
    ///
    /// - Parameter label: The host's last label, lowercased.
    func isPublicTopLevelDomain(_ label: String) -> Bool
}

public extension BrowserHostNormalizing {
    /// Conformers without a suffix list accept every label; the router still
    /// requires a dotted host.
    func isPublicTopLevelDomain(_ label: String) -> Bool { true }
}
