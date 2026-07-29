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
        request.setValue("1", forHTTPHeaderField: "X-Cmux-App-Session-Handoff")
        request.setValue("no-referrer", forHTTPHeaderField: "Referrer-Policy")
        request.httpBody = body.data(using: .utf8)
        return request
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
