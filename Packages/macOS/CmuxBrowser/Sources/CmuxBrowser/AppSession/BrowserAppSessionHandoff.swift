public import Foundation

/// Native Stack credentials used to establish a browser-only web session.
public struct BrowserAppSessionTokens: Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String

    public init(accessToken: String?, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Resolves links that explicitly request a full browser pane in cmux.
public struct BrowserAppLinkOpenRequest: Equatable, Sendable {
    public static let queryItemName = "cmux_open_in_browser"
    public static let splitRightValue = "split-right"

    public let destinationURL: URL

    public init?(url: URL, webOrigin: URL) {
        guard Self.matchesOrigin(url, webOrigin),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: {
                  $0.name == Self.queryItemName && $0.value == Self.splitRightValue
              }) == true else {
            return nil
        }

        components.queryItems = components.queryItems?.filter {
            $0.name != Self.queryItemName
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        guard let destinationURL = components.url else { return nil }
        self.destinationURL = destinationURL
    }

    fileprivate static func matchesOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Builds a one-time native-to-web session handoff for a single cmux origin.
public struct BrowserAppSessionHandoff: Sendable {
    public let webOrigin: URL

    public init(webOrigin: URL) {
        self.webOrigin = webOrigin
    }

    public func request(
        destinationURL: URL,
        tokens: BrowserAppSessionTokens
    ) -> URLRequest? {
        guard shouldHandoff(to: destinationURL),
              let handoffURL = URL(
                  string: "/handler/app-session-handoff",
                  relativeTo: webOrigin
              )?.absoluteURL else {
            return nil
        }

        let pairs: [(String, String)] = [
            ("refresh_token", tokens.refreshToken),
            ("access_token", tokens.accessToken ?? ""),
            ("after", relativePath(destinationURL)),
        ].filter { !$0.1.isEmpty }
        let body = pairs
            .map { "\($0.0)=\(formURLEncode($0.1))" }
            .joined(separator: "&")

        var request = URLRequest(url: handoffURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("no-referrer", forHTTPHeaderField: "Referrer-Policy")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    public func shouldDeleteCookie(
        name: String,
        domain: String,
        projectID: String
    ) -> Bool {
        guard isStackCookie(name, projectID: projectID),
              let host = webOrigin.host?.lowercased() else {
            return false
        }
        let normalizedDomain = domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedDomain == host
    }

    private func shouldHandoff(to destinationURL: URL) -> Bool {
        guard BrowserAppLinkOpenRequest.matchesOrigin(destinationURL, webOrigin),
              let scheme = destinationURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return destinationURL.path != "/handler/app-session-handoff"
    }

    private func isStackCookie(_ name: String, projectID: String) -> Bool {
        let refreshName = "stack-refresh-\(projectID)"
        let hexclaveRefreshName = "hexclave-refresh-\(projectID)"
        return name == "stack-access"
            || name == "__Host-stack-access"
            || name == "__Secure-stack-access"
            || name == "hexclave-access"
            || name == "__Host-hexclave-access"
            || name == "__Secure-hexclave-access"
            || name == "stack-refresh"
            || name == "__Host-stack-refresh"
            || name == "__Secure-stack-refresh"
            || name == refreshName
            || name == "__Host-\(refreshName)"
            || name == "__Secure-\(refreshName)"
            || name.hasPrefix("\(refreshName)--")
            || name.hasPrefix("__Host-\(refreshName)--")
            || name.hasPrefix("__Secure-\(refreshName)--")
            || name == hexclaveRefreshName
            || name == "__Host-\(hexclaveRefreshName)"
            || name == "__Secure-\(hexclaveRefreshName)"
            || name.hasPrefix("\(hexclaveRefreshName)--")
            || name.hasPrefix("__Host-\(hexclaveRefreshName)--")
            || name.hasPrefix("__Secure-\(hexclaveRefreshName)--")
    }

    private func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func relativePath(_ url: URL) -> String {
        var result = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            result += "?\(query)"
        }
        if let fragment = url.fragment, !fragment.isEmpty {
            result += "#\(fragment)"
        }
        return result
    }
}
