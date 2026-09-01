import Foundation

/// Validates webhook transport and identifies headers that carry credentials.
///
/// Webhooks without credential-bearing headers may use HTTP for compatibility.
/// Once a credential-like header (or URL user information) is present, the
/// request must remain on HTTPS and sensitive headers are removed before a
/// cross-origin redirect is followed.
nonisolated struct AutomationWebhookPolicy: Sendable {
    private let sensitiveFragments = [
        "authorization", "proxyauthorization", "token", "secret", "password",
        "apikey", "credential", "cookie", "privatekey", "session"
    ]

    /// Creates the product's default webhook transport policy.
    init() {}

    /// Returns the lowercased header names that must not cross an origin.
    func credentialHeaderNames(in headers: [String: String]) -> Set<String> {
        Set(headers.keys.compactMap { key in
            isCredentialBearingHeader(key) ? key.lowercased() : nil
        })
    }

    /// Returns whether a URL and its headers satisfy the webhook transport policy.
    func isValid(url: URL, headers: [String: String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              url.host != nil,
              scheme == "http" || scheme == "https" else {
            return false
        }
        let carriesCredentials = !credentialHeaderNames(in: headers).isEmpty
            || url.user != nil
            || url.password != nil
        return !carriesCredentials || scheme == "https"
    }

    /// Returns whether a header name can carry a credential or session secret.
    func isCredentialBearingHeader(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveFragments.contains { normalized.contains($0) }
    }
}
