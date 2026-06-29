public import Foundation

/// Recognizes and parses cmux auth callback URLs.
///
/// Accepts the built-in cmux callback schemes (`cmux`, `cmux-nightly`,
/// and `cmux-dev`) plus an optional runtime override (e.g. a per-tag Debug
/// build's unique scheme, or the selected iOS release/TestFlight scheme),
/// injected at construction so the type never reads the process environment
/// itself. A pure value; construct it once at the composition root and inject
/// it.
public struct AuthCallbackRouter: Sendable {
    private static let builtInSchemes: Set<String> = ["cmux", "cmux-nightly", "cmux-dev"]
    private let extraAllowedScheme: String?

    /// Creates a router.
    /// - Parameter extraAllowedScheme: An additional callback scheme to honor
    ///   (the composition root passes its resolved runtime scheme so any
    ///   `CMUX_AUTH_CALLBACK_SCHEME` override round-trips).
    public init(extraAllowedScheme: String? = nil) {
        self.extraAllowedScheme = extraAllowedScheme?.lowercased()
    }

    /// Whether `url` is a cmux auth callback (`<scheme>://auth-callback`).
    public func isAuthCallbackURL(_ url: URL) -> Bool {
        guard isAllowedScheme(url.scheme) else { return false }
        return Self.callbackTarget(for: url) == "auth-callback"
    }

    /// Parse the token payload from a callback URL, or `nil` when the URL is
    /// not a valid auth callback.
    public func callbackPayload(from url: URL) -> AuthCallbackPayload? {
        guard isAuthCallbackURL(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        guard let refreshToken = Self.queryValue(named: "stack_refresh", in: components)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty,
              let accessCookie = Self.queryValue(named: "stack_access", in: components)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessCookie.isEmpty,
              let accessToken = Self.decodeAccessToken(from: accessCookie) else {
            return nil
        }

        return AuthCallbackPayload(
            refreshToken: refreshToken,
            accessToken: accessToken
        )
    }

    private func isAllowedScheme(_ scheme: String?) -> Bool {
        guard let normalized = scheme?.lowercased() else { return false }
        if Self.builtInSchemes.contains(normalized) {
            return true
        }
        return normalized == extraAllowedScheme
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
