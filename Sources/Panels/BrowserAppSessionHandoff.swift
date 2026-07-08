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
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
            URLQueryItem(name: "access_token", value: tokens.accessToken),
            URLQueryItem(name: "after", value: relativePath(destinationURL)),
        ].filter { $0.value?.isEmpty == false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-referrer", forHTTPHeaderField: "Referrer-Policy")
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
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
