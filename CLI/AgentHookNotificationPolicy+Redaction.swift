import Foundation

extension AgentHookNotificationPolicy {
    /// Redacts credentials before a command reaches durable hook state or UI.
    static func redactSensitiveCommand(_ value: String) -> String {
        let boundedValue = value.utf8.count > 8_192
            ? String(decoding: value.utf8.prefix(8_191), as: UTF8.self) + "…"
            : value
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#, "<token>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#, "Bearer <token>"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "<token>"),
            (#"(?i)\b(?:authorization|proxy-authorization)\s*:\s*[^\s'\";&|]+(?:\s+[^\s'\";&|]+)*"#, "<credential>:<token>"),
            (#"(?i)\b(?:x[-_])?(?:api[-_]?key|password|secret|token|authorization|cookie)\s*:\s*(?:Bearer\s+)?(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>:<token>"),
            (#"(?i)(?:^|\s)--?[A-Za-z0-9]*(?:api[-_]?key|access[-_]?key|password|secret|token|authorization|cookie|passphrase)[A-Za-z0-9_-]*(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)--?(?:api[-_]?key|password|secret|token|authorization|cookie)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>=<token>"),
            (#"(?i)(?:^|\s)(?:-u|--user)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:--passphrase|--password|--pass|--auth|--credential)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:-pass|-a|-p)(?:=|\s+|(?=[^\s]))(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)\b[A-Za-z_]*(?:api[_-]?key|access[_-]?key|password|secret|token|authorization|cookie)[A-Za-z0-9_]*\s*=\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#, "<credential>=<token>"),
            (#"(?i)\b(?:api[_-]?key|access[_-]?key|password|secret|token|authorization|cookie)\s*=\s*[^\s;&|]+"#, "<credential>=<token>"),
            // Consume credential options and their values before generic token
            // matching can replace a token-like option name on its own.
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>"),
        ]
        return patterns.reduce(boundedValue) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}
