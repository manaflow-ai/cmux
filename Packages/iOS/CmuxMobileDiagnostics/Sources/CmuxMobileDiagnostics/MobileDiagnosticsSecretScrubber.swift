public import Foundation

/// Redacts credentials and token-shaped values from mobile diagnostics text.
public struct MobileDiagnosticsSecretScrubber: Sendable {
    /// The marker used when a secret is removed.
    public let redaction: String

    /// Create a secret scrubber.
    ///
    /// - Parameter redaction: Replacement marker for detected secrets.
    public init(redaction: String = "<redacted>") {
        self.redaction = redaction
    }

    /// Redact credentials from text.
    ///
    /// - Parameter text: Unscrubbed diagnostics text.
    /// - Returns: Text with token, credential, JWT, authorization, and email
    ///   values redacted.
    public func scrub(_ text: String) -> String {
        var redacted = text
        for pattern in Self.secretPatterns {
            let replacement = pattern.replacement.replacingOccurrences(
                of: "{redaction}",
                with: redaction
            )
            redacted = redacted.replacingOccurrences(
                of: pattern.match,
                with: replacement,
                options: .regularExpression
            )
        }
        return redacted
    }

    private static let secretPatterns: [(match: String, replacement: String)] = [
        (
            #"(?i)\b(authorization|x-stack-access-token|x-stack-refresh-token)\s*[:=]\s*(?:Bearer\s+)?([^\s,;)]+)"#,
            "$1={redaction}"
        ),
        (
            #"(?i)(["']?(?:stack_access|stack_refresh|access_token|refresh_token|id_token|auth_token|token|password|passwd|secret|api_key|apikey|client_secret|login_code|polling_code|cmux_auth_state|state|code)["']?\s*:\s*["'])([^"']+)(["'])"#,
            "$1{redaction}$3"
        ),
        (
            #"(?i)\b(stack_access|stack_refresh|access_token|refresh_token|id_token|auth_token|token|password|passwd|secret|api_key|apikey|client_secret|login_code|polling_code|cmux_auth_state|state|code)=([^\s&#,)]+)"#,
            "$1={redaction}"
        ),
        (
            #"(?i)(stack_access|stack_refresh|access_token|refresh_token|id_token|auth_token|token|password|passwd|secret|api_key|apikey|client_secret|login_code|polling_code|cmux_auth_state|state|code)%3[dD]([^\s&#,)]+)"#,
            "$1%3D{redaction}"
        ),
        (
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]{12,}"#,
            "Bearer {redaction}"
        ),
        (
            #"[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
            "{redaction}"
        ),
        (
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            "{redaction}"
        ),
    ]
}
