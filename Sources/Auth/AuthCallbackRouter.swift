import Foundation

struct CMUXAuthCallbackPayload: Equatable, Sendable {
    let refreshToken: String
    let accessToken: String
}

enum AuthCallbackRouter {
    static func isAuthCallbackURL(_ url: URL) -> Bool {
        guard isAllowedScheme(url.scheme) else { return false }
        return callbackTarget(for: url) == "auth-callback"
    }

    static func callbackPayload(from url: URL) -> CMUXAuthCallbackPayload? {
        guard isAuthCallbackURL(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        guard let refreshToken = queryValue(named: "stack_refresh", in: components)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty,
              let accessCookie = queryValue(named: "stack_access", in: components)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessCookie.isEmpty,
              let accessToken = decodeAccessToken(from: accessCookie) else {
            return nil
        }

        return CMUXAuthCallbackPayload(
            refreshToken: refreshToken,
            accessToken: accessToken
        )
    }

    private static func isAllowedScheme(_ scheme: String?) -> Bool {
        guard let normalized = scheme?.lowercased() else { return false }
        return normalized == "manaflow" || normalized == "manaflow-dev"
            || normalized == "cmux" || normalized == "cmux-dev"
    }

    private static func callbackTarget(for url: URL) -> String {
        let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if let host, !host.isEmpty {
            return host
        }
        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func queryValue(named name: String, in components: URLComponents) -> String? {
        components.queryItems?
            .last(where: { $0.name == name })?
            .value
    }

    private static func decodeAccessToken(from accessCookie: String) -> String? {
        guard accessCookie.hasPrefix("[") else {
            return accessCookie
        }
        guard let data = accessCookie.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let accessToken = array[1] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        return accessToken
    }
}
