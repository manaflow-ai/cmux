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
        if normalized == "cmux" || normalized == "cmux-dev" {
            return true
        }
        // Honor the runtime override so any AuthEnvironment.callbackScheme
        // chosen via CMUX_AUTH_CALLBACK_SCHEME round-trips through the
        // router (e.g. per-tag Debug builds with a unique scheme).
        return normalized == AuthEnvironment.callbackScheme.lowercased()
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
        // Use the first matching query item so a maliciously appended
        // duplicate (`?stack_refresh=real&stack_refresh=attacker`) can't
        // override the legitimate value.
        components.queryItems?
            .first(where: { $0.name == name })?
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
