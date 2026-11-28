import Foundation

/// Replaces known secret shapes in notification text with `[redacted]`
/// before it leaves the Mac for the feed (and from there APNs and the lock
/// screen). A best-effort net, not a guarantee: terminal notifications stay
/// off by default (`feed.mirrorNotifications.terminal`) because program
/// output can hold secrets of any shape.
nonisolated enum FeedSecretScrubber {
    static let marker = "[redacted]"

    /// Patterns whose whole match is a secret.
    private static let whole: [NSRegularExpression] = [
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        #"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"#,
        #"\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9_-]{16,}"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{30,}"#,
        #"\bnpm_[A-Za-z0-9]{30,}"#,
        #"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// `Bearer value`: the value is the secret (before `name: value`, which would stop at "Bearer").
    private static let bearer = try? NSRegularExpression(pattern: #"(?i)(\b(?:bearer|basic)\s+)([^\s"',;]{4,})"#)
    /// `name: value` / `name=value`: the value is the secret.
    private static let valued = try? NSRegularExpression(
        pattern: #"(?i)(\b[a-z0-9_.-]*(?:api[_-]?key|token|secret|passw(?:or)?d|pwd|credential|auth(?:orization)?)[a-z0-9_.-]*["']?\s*[:=]\s*["']?)([^\s"',;]{4,})"#
    )

    static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for pattern in whole {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: marker)
        }
        for pattern in [bearer, valued].compactMap({ $0 }) {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\(marker)")
        }
        return out
    }
}
