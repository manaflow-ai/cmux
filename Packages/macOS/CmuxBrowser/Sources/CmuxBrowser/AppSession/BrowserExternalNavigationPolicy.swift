public import Foundation

/// Decides whether a trusted app-web surface explicitly requests the system browser.
public struct BrowserExternalNavigationPolicy: Equatable, Sendable {
    public let trustedOrigin: URL

    /// Creates a policy pinned to the exact app-web origin.
    public init(trustedOrigin: URL) {
        self.trustedOrigin = trustedOrigin
    }

    /// Returns true only when a trusted app-web source activates a same-origin
    /// web URL with an explicit intent marker.
    public func shouldOpenInSystemBrowser(
        _ url: URL,
        sourceURL: URL?
    ) -> Bool {
        guard let sourceURL,
              BrowserAppWebOrigin(trustedOrigin).contains(sourceURL),
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
        BrowserAppWebOrigin(trustedOrigin).contains(url)
    }
}
