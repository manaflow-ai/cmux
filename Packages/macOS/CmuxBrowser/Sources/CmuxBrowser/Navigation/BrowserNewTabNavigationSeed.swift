public import Foundation

/// Carries the request and one-shot HTTP bypass needed to seed a retargeted tab.
public struct BrowserNewTabNavigationSeed: Sendable {
    /// The destination URL of the retargeted navigation.
    public let url: URL
    /// The original request, preserved so method/body/headers survive retargeting.
    public let initialRequest: URLRequest
    /// A host whose one-shot insecure-HTTP block should be bypassed, if any.
    public let bypassInsecureHTTPHostOnce: String?

    /// Creates a seed from its component values.
    public init(url: URL, initialRequest: URLRequest, bypassInsecureHTTPHostOnce: String?) {
        self.url = url
        self.initialRequest = initialRequest
        self.bypassInsecureHTTPHostOnce = bypassInsecureHTTPHostOnce
    }

    /// Preserves the original request metadata for a retargeted new-tab navigation.
    public static func make(
        from request: URLRequest,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserNewTabNavigationSeed? {
        guard let url = request.url else { return nil }
        return BrowserNewTabNavigationSeed(
            url: url,
            initialRequest: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
    }
}
