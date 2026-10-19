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
            (#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]+@"#, "$1<redacted>@"),
            // Secret query values, including bracketed namespaces and
            // provider prefixes such as `auth[token]` and `X-Amz-Signature`.
            (#"(?i)([?#&](?:[A-Za-z0-9]+[-_.\[\]]+)*(?:auth|authorization|code|credentials?|key|password|passwd|pwd|secret|sig|signature|token|apikey)(?:[-_.\[\]]+[A-Za-z0-9]*)*=)[^&\s"']+"#, "$1<redacted>"),
            // Cookie and authorization headers contain structured lists whose
            // later fields are just as sensitive as the first one.
            (#"(?i)\b((?:proxy-)?authorization|(?:set-)?cookie)(\s*[:=]\s*)[^\r\n]+"#, "$1$2<redacted>"),
            // camelCase assignments such as `clientSecret` and
            // `secretAccessKey`; the capitalized component is the boundary.
            (#"\b([a-z][A-Za-z0-9]*(?:Secret|Password|Passwd|Pwd|Token|Credential|APIKey|ApiKey|AccessKey|PrivateKey)[A-Za-z0-9]*)((?:\\+)?"?\s*[:=]\s*)((?:\\+)?"[^"\r\n]*(?:\\+)?"|(?:\\+)?'[^'\r\n]*(?:\\+)?'|[^\s,;}]+(?:\s+[^\s,;}]+)?)"#, "$1$2<redacted>"),
            // Header or assignment forms. The full identifier is retained so an
            // environment-style prefix (`AWS_SECRET_ACCESS_KEY`) cannot put the
            // credential marker behind an underscore word-boundary bypass.
            (#"(?i)\b((?:[A-Za-z0-9]+[_-])*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[_-]?key|access[_-]?key|private[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?key|client[_-]?secret|credentials?|secret|password|passwd|pwd|token|auth)(?:[_-][A-Za-z0-9]+)*)((?:\\+)?"?\s*[:=]\s*)((?:\\+)?"[^"\r\n]*(?:\\+)?"|(?:\\+)?'[^'\r\n]*(?:\\+)?'|[^\s,;}]+(?:\s+[^\s,;}]+)?)"#, "$1$2<redacted>"),
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
