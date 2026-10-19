import Foundation

/// Removes secrets from text before it is journaled: auth headers, cookies, bearer and API
/// tokens, JWTs, URL credentials and secret query values, and long opaque blobs.
///
/// ```swift
/// ErrorRedactor().redact("Authorization: Bearer abc.def") // "Authorization=<redacted>"
/// ```
public struct ErrorRedactor {
    private let rules: [(NSRegularExpression, String)]

    /// Makes a redactor with the built-in rules.
    public init() {
        let patterns: [(String, String)] = [
            // URL credentials: scheme://user:password@host
            (#"(://)[^/\s:@]+:[^/\s@]+@"#, "$1<redacted>@"),
            // Secret query values.
            (#"([?&](?:access_token|refresh_token|token|key|api_key|apikey|sig|signature|code|auth|password|secret)=)[^&\s"']+"#, "$1<redacted>"),
            // Header or assignment forms: authorization: …, cookie=…, "token":"…"
            (#"(?i)\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?key|client[_-]?secret|secret|password|passwd|token)("?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+(?:\s+[^\s,;}]+)?)"#, "$1$2<redacted>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#, "<jwt>"),
            (#"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|AKIA|ASIA)[-_]?[A-Za-z0-9_-]{12,}"#, "<redacted>"),
            // Long opaque runs (keys, hashes, base64 payloads).
            (#"[A-Za-z0-9+/_=-]{48,}"#, "<blob>"),
        ]
        rules = patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) } // swiftlint:disable:this force_try
    }

    /// Returns `text` with every secret replaced by a placeholder.
    public func redact(_ text: String) -> String {
        var text = text
        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: replacement)
        }
        return text
    }
}
