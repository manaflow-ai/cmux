import Foundation

/// The claims of an access token's JWT payload, decoded locally with no
/// network call and no signature check. Only for local decisions that must
/// never grant anything (a lifetime log, whether a cached identity still
/// names the token's account); the server alone trusts a token.
enum AccessTokenClaims {
    static func payload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The Stack user the token was issued to (`sub`), nil for a token that is not a readable JWT.
    static func subject(_ token: String?) -> String? {
        guard let subject = payload(token)?["sub"] as? String, !subject.isEmpty else { return nil }
        return subject
    }
}
