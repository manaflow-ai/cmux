public import Foundation

/// Decides whether a trusted app-web URL explicitly requests the system browser.
public struct BrowserExternalNavigationPolicy: Equatable, Sendable {
    public let trustedOrigin: URL

    /// Creates a policy pinned to the exact origin allowed to request external navigation.
    public init(trustedOrigin: URL) {
        self.trustedOrigin = trustedOrigin
    }

    /// Returns true only for an HTTP(S) URL on the trusted origin with a nonzero intent marker.
    public func shouldOpenInSystemBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              sameOrigin(url, trustedOrigin) else {
            return false
        }
        return components.queryItems?.contains(where: {
            $0.name == "cmux_external_browser" && $0.value != "0"
        }) == true
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsComponents = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let rhsComponents = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              let lhsScheme = lhsComponents.scheme?.lowercased(),
              let rhsScheme = rhsComponents.scheme?.lowercased(),
              let lhsHost = lhsComponents.host?.lowercased(),
              let rhsHost = rhsComponents.host?.lowercased() else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhsComponents) == effectivePort(rhsComponents)
    }

    private func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port {
            return port
        }
        return switch components.scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
