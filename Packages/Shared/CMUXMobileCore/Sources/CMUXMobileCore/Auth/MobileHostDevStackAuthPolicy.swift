#if DEBUG
import Foundation

/// Dev-only loopback token check comparing a client-presented dev Stack auth
/// token against the token this Mac currently accepts.
///
/// Compiled out of release builds. Both tokens are trimmed of surrounding
/// whitespace and an empty result is treated as absent, so an unconfigured
/// accepted token always rejects. Holds no state.
public struct MobileHostDevStackAuthPolicy: Sendable {
    public init() {}

    public func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public func authorize(providedToken: String, acceptedToken: String?) -> Bool {
        guard let acceptedToken = normalizedToken(acceptedToken) else {
            return false
        }
        return normalizedToken(providedToken) == acceptedToken
    }
}
#endif
