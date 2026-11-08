public import Foundation

/// Builds a one-time native-to-web session handoff for a single cmux origin.
public struct BrowserAppSessionHandoff: Sendable {
    /// The web origin allowed to receive native session credentials.
    public let webOrigin: URL

    /// Creates a handoff builder restricted to `webOrigin`.
    public init(webOrigin: URL) {
        self.webOrigin = webOrigin
    }

    /// Creates the authenticated POST request for an allowed destination.
    public func request(
        destinationURL: URL,
        tokens: BrowserAppSessionTokens
    ) -> URLRequest? {
        guard !tokens.accessToken.isEmpty,
              !tokens.refreshToken.isEmpty,
              shouldHandoff(to: destinationURL),
              let handoffURL = URL(
                  string: "/handler/app-session-handoff",
                  relativeTo: webOrigin
              )?.absoluteURL else {
            return nil
        }

        let pairs: [(String, String)] = [
            ("access_token", tokens.accessToken),
            ("refresh_token", tokens.refreshToken),
            ("after", relativePath(destinationURL)),
        ]
        let body = pairs
            .map { "\($0.0)=\(formURLEncode($0.1))" }
            .joined(separator: "&")

        var request = URLRequest(url: handoffURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("1", forHTTPHeaderField: "X-Cmux-App-Session-Handoff")
        request.setValue("cookies", forHTTPHeaderField: "X-Cmux-App-Session-Response")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    /// Extracts the complete Stack cookie pair from a native exchange response.
    /// Returning `nil` fails the handoff closed when the server, a proxy, or an
    /// authentication failure returns anything except the expected response.
    public func sessionCookies(
        from response: HTTPURLResponse,
        projectID: String
    ) -> [HTTPCookie]? {
        guard response.statusCode == 204,
              response.value(forHTTPHeaderField: "X-Cmux-App-Session-Handoff") == "ready",
              let responseURL = response.url,
              BrowserAppWebOrigin(webOrigin).contains(responseURL) else {
            return nil
        }

        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie") else {
            return nil
        }
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookie],
            for: responseURL
        ).filter {
            shouldDeleteCookie(
                name: $0.name,
                domain: $0.domain,
                projectID: projectID
            )
        }
        let names = Set(cookies.map(\.name))
        let accessNames = ["stack-access", "hexclave-access"]
        let refreshNames = [
            "stack-refresh-\(projectID)",
            "hexclave-refresh-\(projectID)",
        ]
        let prefixes = ["", "__Host-", "__Secure-"]
        let hasAccess = prefixes.contains { prefix in
            accessNames.contains { names.contains("\(prefix)\($0)") }
        }
        let hasRefresh = prefixes.contains { prefix in
            refreshNames.contains { base in
                names.contains("\(prefix)\(base)")
                    || names.contains { $0.hasPrefix("\(prefix)\(base)--") }
            }
        }
        return hasAccess && hasRefresh ? cookies : nil
    }

    /// Returns whether a Stack session cookie belongs to this handoff's origin.
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
        guard BrowserAppWebOrigin(webOrigin).contains(destinationURL),
              let scheme = destinationURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return destinationURL.path != "/handler/app-session-handoff"
    }

    private func isStackCookie(_ name: String, projectID: String) -> Bool {
        let prefixes = ["", "__Host-", "__Secure-"]
        let exactNames = [
            "stack-access",
            "hexclave-access",
            "stack-refresh",
            "hexclave-refresh",
        ]
        let scopedRefreshNames = [
            "stack-refresh-\(projectID)",
            "hexclave-refresh-\(projectID)",
        ]

        return prefixes.contains { prefix in
            exactNames.contains { name == "\(prefix)\($0)" }
                || scopedRefreshNames.contains {
                    name == "\(prefix)\($0)" || name.hasPrefix("\(prefix)\($0)--")
                }
        }
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
