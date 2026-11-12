import Foundation

/// Lifetime facts of an access token for diagnostics: seconds until `exp`
/// and the issued lifetime (`exp - iat`). Reads only the JWT claims, never
/// verifies or logs the token itself.
struct AccessTokenLifetime: Sendable, Equatable {
    let expiresInSeconds: Int
    let lifetimeSeconds: Int?

    init?(_ token: String?, now: Date = Date()) {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        expiresInSeconds = Int(exp - now.timeIntervalSince1970)
        if let iat = (claims["iat"] as? NSNumber)?.doubleValue {
            lifetimeSeconds = Int(exp - iat)
        } else {
            lifetimeSeconds = nil
        }
    }

    /// `accessExpiresInSec=N accessLifetimeSec=M` for a debug log line.
    static func logFields(_ token: String?) -> String {
        guard let lifetime = AccessTokenLifetime(token) else { return "accessExpiresInSec=nil" }
        return "accessExpiresInSec=\(lifetime.expiresInSeconds) accessLifetimeSec=\(lifetime.lifetimeSeconds.map(String.init) ?? "nil")"
    }
}
