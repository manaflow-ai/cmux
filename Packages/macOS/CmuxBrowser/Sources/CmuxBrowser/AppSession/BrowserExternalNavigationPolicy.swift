public import Foundation

/// Decides whether a trusted app-web surface explicitly requests the system browser.
public struct BrowserExternalNavigationPolicy: Equatable, Sendable {
    public let trustedOrigin: URL
    public let billingCheckoutURL: URL?

    /// Creates a policy pinned to the app-web origin and optional billing checkout URL.
    public init(
        trustedOrigin: URL,
        billingCheckoutURL: URL? = nil
    ) {
        self.trustedOrigin = trustedOrigin
        self.billingCheckoutURL = billingCheckoutURL
    }

    /// Returns true only when a trusted app-web source activates a safe web URL
    /// with an explicit intent marker. The destination may use a separate
    /// configured billing origin.
    public func shouldOpenInSystemBrowser(
        _ url: URL,
        sourceURL: URL?
    ) -> Bool {
        guard let sourceURL,
              BrowserAppWebOrigin(trustedOrigin).containsAppSurface(sourceURL),
              isSafeWebDestination(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: {
                  $0.name == "cmux_external_browser" && $0.value == "1"
              }) == true else {
            return false
        }
        return true
    }

    private func isSafeWebDestination(_ url: URL) -> Bool {
        if BrowserAppWebOrigin(trustedOrigin).contains(url) {
            return true
        }
        guard let billingCheckoutURL,
              isSecureBillingURL(billingCheckoutURL),
              url.user == nil,
              url.password == nil,
              BrowserAppWebOrigin(billingCheckoutURL).contains(url) else {
            return false
        }
        return normalizedPath(url) == normalizedPath(billingCheckoutURL)
    }

    private func isSecureBillingURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" {
            return url.host != nil
        }
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private func normalizedPath(_ url: URL) -> String {
        url.path.count > 1 && url.path.hasSuffix("/")
            ? String(url.path.dropLast())
            : url.path
    }
}
