import Foundation

struct BrowserAppSessionTokens: Equatable {
    let accessToken: String?
    let refreshToken: String
}

struct BrowserAppSessionHandoff {
    static func shouldHandoff(destinationURL: URL, webOrigin: URL) -> Bool {
        guard matchesOrigin(destinationURL, webOrigin) else { return false }
        guard let scheme = destinationURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return destinationURL.path != "/handler/app-session-handoff"
    }

    static func handoffRequest(
        destinationURL: URL,
        webOrigin: URL,
        tokens: BrowserAppSessionTokens
    ) -> URLRequest? {
        guard shouldHandoff(destinationURL: destinationURL, webOrigin: webOrigin) else {
            return nil
        }
        guard let url = URLComponents(
            url: webOrigin.appendingPathComponent("handler/app-session-handoff"),
            resolvingAgainstBaseURL: false
        )?.url else {
            return nil
        }
        // Build the form body by hand: URLComponents.percentEncodedQuery leaves
        // "+" literal, and application/x-www-form-urlencoded decodes "+" to a
        // space, silently corrupting any token that contains "+". Percent-encode
        // every value with a set that excludes "+", "&", "=", and "%".
        let pairs: [(String, String)] = [
            ("refresh_token", tokens.refreshToken),
            ("access_token", tokens.accessToken ?? ""),
            ("after", relativePath(destinationURL)),
        ].filter { !$0.1.isEmpty }
        let body = pairs
            .map { "\($0.0)=\(formURLEncode($0.1))" }
            .joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-referrer", forHTTPHeaderField: "Referrer-Policy")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    static func isStackCookie(_ name: String, projectId: String) -> Bool {
        let refreshName = "stack-refresh-\(projectId)"
        return name == "stack-access" ||
            name == "__Host-stack-access" ||
            name == "__Secure-stack-access" ||
            name == "stack-refresh" ||
            name == "__Host-stack-refresh" ||
            name == "__Secure-stack-refresh" ||
            name == refreshName ||
            name == "__Host-\(refreshName)" ||
            name == "__Secure-\(refreshName)" ||
            name.hasPrefix("\(refreshName)--") ||
            name.hasPrefix("__Host-\(refreshName)--") ||
            name.hasPrefix("__Secure-\(refreshName)--")
    }

    static func shouldDeleteCookie(
        name: String,
        domain: String,
        webOrigin: URL,
        projectId: String
    ) -> Bool {
        guard isStackCookie(name, projectId: projectId),
              let host = webOrigin.host?.lowercased() else {
            return false
        }
        let normalizedDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedDomain == host
    }

    private static func matchesOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
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

    private static func formURLEncode(_ value: String) -> String {
        // application/x-www-form-urlencoded value encoding: percent-encode
        // everything except RFC 3986 unreserved characters, so "+", "&", "=",
        // "%", and space are all escaped. A "+" left literal would decode back
        // to a space and silently corrupt a token that contains "+".
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func relativePath(_ url: URL) -> String {
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
