import Foundation

extension HostBrowserSignInFlow {
    nonisolated func authCallbackState(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value
    }

    nonisolated func redactedAuthState(_ state: String) -> String {
        "\(state.prefix(8))..."
    }

    nonisolated func authCallbackSummary(_ url: URL) -> String {
        let scheme = url.scheme ?? "nil"
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name)
            .joined(separator: ",") ?? ""
        return "scheme=\(scheme) target=\(target.isEmpty ? "nil" : target) queryKeys=\(queryItems.isEmpty ? "none" : queryItems)"
    }

    /// Which account a handed-back access token was minted for, for the auth log: the SDK
    /// reports an anonymous user, a restricted one and a rejected token all as
    /// `USER_NOT_SIGNED_IN`. Read from the token's own claims (no network); never the token.
    nonisolated static func accessTokenClaimsSummary(_ token: String, now: Date) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return "claims=unreadable" }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "claims=unreadable"
        }
        func flag(_ name: String) -> String { (claims[name] as? Bool).map(String.init) ?? "absent" }
        let expired = (claims["exp"] as? Double).map { String(Date(timeIntervalSince1970: $0) <= now) } ?? "absent"
        return "is_anonymous=\(flag("is_anonymous")) is_restricted=\(flag("is_restricted")) expired=\(expired)"
    }

    nonisolated func sessionResultSummary(_ result: HostBrowserAuthSessionResult) -> String {
        switch result {
        case let .callback(url):
            return "result=callback \(authCallbackSummary(url))"
        case let .cancelled(reason):
            return "result=cancelled reason=\(reason)"
        case let .failed(reason):
            return "result=failed reason=\(reason)"
        }
    }
}
