public import Foundation

/// Decides whether a trusted app-web URL explicitly requests the system browser.
public struct BrowserExternalNavigationPolicy: Equatable, Sendable {
    public let trustedOrigin: URL

    /// Creates a policy pinned to the exact origin allowed to request external navigation.
    public init(trustedOrigin: URL) {
        self.trustedOrigin = trustedOrigin
    }

    /// Returns true only for an HTTP(S) URL on the trusted origin with an explicit intent marker.
    public func shouldOpenInSystemBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              BrowserAppWebOrigin(trustedOrigin).contains(url) else {
            return false
        }
        return components.queryItems?.contains(where: {
            $0.name == "cmux_external_browser" && $0.value == "1"
        }) == true
    }
}
