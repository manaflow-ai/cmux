public import Foundation

/// Decides whether a trusted app-web surface explicitly requests the system browser.
public struct BrowserExternalNavigationPolicy: Equatable, Sendable {
    public let trustedOrigin: URL

    /// Creates a policy pinned to the exact origin allowed to request external navigation.
    public init(trustedOrigin: URL) {
        self.trustedOrigin = trustedOrigin
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
        switch url.scheme?.lowercased() {
        case "https":
            return url.host != nil
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost"
                || host == "127.0.0.1"
                || host == "::1"
        default:
            return false
        }
    }
}
