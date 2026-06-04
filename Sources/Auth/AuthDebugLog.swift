import Foundation
import os

/// Redacted auth diagnostics, shared by the token stores and sign-in flows.
///
/// Logs to the unified log (`com.cmuxterm.app` / `auth`) in all builds. DEBUG
/// builds additionally append to `/tmp/cmux-auth-debug.log` (0600) so a
/// sign-in repro can be tailed without Console.app. Token material, JWTs, and
/// emails are redacted before any sink sees the message. A pure value;
/// construct it freely and store it as a `let` on the consumer.
struct AuthDebugLog: Sendable {
    init() {}

    func log(_ message: String) {
        let redactedMessage = Self.redacted(message)
        Self.logger.log(level: Self.logType(for: redactedMessage), "\(redactedMessage, privacy: .public)")
        #if DEBUG
        let line = "[\(Self.timestampFormatter.string(from: Date()))] auth: \(redactedMessage)\n"
        Self.appendToDebugFile(line)
        #endif
    }

    #if DEBUG
    /// Append one line with `O_APPEND` so concurrent logs from different actor
    /// executors (the token stores, the browser flow) stay line-atomic instead
    /// of interleaving through a shared seek+write.
    private static func appendToDebugFile(_ line: String) {
        let fd = open(debugLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = write(fd, baseAddress, buffer.count)
        }
    }
    #endif

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "auth")
    private static let debugLogPath = "/tmp/cmux-auth-debug.log"

    // ISO8601DateFormatter is expensive to construct (calendar + locale +
    // time zone). Reuse one instance across the high-frequency log path.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func logType(for message: String) -> OSLogType {
        let lowercased = message.lowercased()
        if lowercased.contains("failed")
            || lowercased.contains("error")
            || lowercased.contains("invalid")
            || lowercased.contains("status=") {
            return .error
        }
        return .debug
    }

    static func redacted(_ message: String) -> String {
        var redacted = message
        let replacements: [(pattern: String, replacement: String)] = [
            (#"(?i)\b(stack_access|stack_refresh|access_token|refresh_token|id_token|token|login_code|polling_code|code|state)=([^\s&#,)]+)"#, "$1=<redacted>"),
            (#"(?i)\b(access|refresh)=([^\s,;)]+)"#, "$1=<redacted>"),
            (#"(?i)\b(authorization|x-stack-access-token|x-stack-refresh-token)\s*[:=]\s*(?:Bearer\s+)?([^\s,;)]+)"#, "$1=<redacted>"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, "<jwt>"),
        ]
        for replacement in replacements {
            redacted = redacted.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }
        return redacted
    }
}
