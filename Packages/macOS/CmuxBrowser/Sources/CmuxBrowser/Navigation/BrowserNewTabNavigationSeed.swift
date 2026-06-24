public import Foundation

/// Carries the request and one-shot HTTP bypass needed to seed a retargeted tab.
///
/// A retargeted new-tab navigation must replay the opener's original
/// ``URLRequest`` verbatim (method, body, headers, cache policy) in the
/// destination tab so the navigation is not silently downgraded to a bare
/// ``URL`` load. The optional ``bypassInsecureHTTPHostOnce`` host carries the
/// single-use plain-HTTP allowlist grant that must travel with the seed.
public struct BrowserNewTabNavigationSeed {
    /// The destination URL extracted from ``initialRequest``.
    public let url: URL

    /// The opener's original request, replayed verbatim in the destination tab.
    public let initialRequest: URLRequest

    /// A host granted a one-shot plain-HTTP bypass for this navigation, if any.
    public let bypassInsecureHTTPHostOnce: String?

    /// Preserves the original request metadata for a retargeted new-tab
    /// navigation. Fails when the request carries no URL, since there is then
    /// nothing to navigate to.
    public init?(request: URLRequest, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let url = request.url else { return nil }
        self.url = url
        self.initialRequest = request
        self.bypassInsecureHTTPHostOnce = bypassInsecureHTTPHostOnce
    }
}
