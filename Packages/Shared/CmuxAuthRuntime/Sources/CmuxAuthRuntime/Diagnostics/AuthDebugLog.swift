import Foundation
import os

/// Redacted auth diagnostics, shared by the token stores and sign-in flows.
///
/// Logs to the unified log (`com.cmuxterm.app` / `auth`) in all builds. macOS
/// DEBUG builds additionally append to `/tmp/cmux-auth-debug.log` (0600) so a
/// sign-in repro can be tailed without Console.app. Token material, JWTs, and
/// emails are redacted before any sink sees the message. A pure value;
/// construct it freely and store it as a `let` on the consumer.
public struct AuthDebugLog: Sendable {
    /// Creates a log value.
    public init() {}

    /// Log one redacted line to the unified log (and, on macOS DEBUG builds,
    /// the `/tmp` debug file).
    public func log(_ message: String) {
        let redactedMessage = Self.redacted(message)
        Self.logger.log(level: authDebugLogType(for: redactedMessage), "\(redactedMessage, privacy: .public)")
        #if DEBUG && os(macOS)
        let line = "[\(Date().formatted(Self.timestampFormat))] auth: \(redactedMessage)\n"
        for path in Self.debugLogPaths(environment: ProcessInfo.processInfo.environment) {
            appendAuthDebugLineToFile(line, path: path)
        }
        #endif
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "auth")

    #if DEBUG && os(macOS)
    private static let debugLogPath = "/tmp/cmux-auth-debug.log"

    // A Sendable value-type format (unlike ISO8601DateFormatter), so the
    // multi-actor logging path needs no unsafe shared formatter.
    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Append one line with `O_APPEND` so concurrent logs from different actor
    /// executors (the token stores, the browser flow) stay line-atomic instead
    /// of interleaving through a shared seek+write.
    static func debugLogPaths(environment: [String: String]) -> [String] {
        var paths = [debugLogPath]
        if let taggedPath = environment["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !taggedPath.isEmpty,
           taggedPath != debugLogPath {
            paths.append(taggedPath)
        }
        return paths
    }

    #endif

    /// Redact token material, JWTs, and emails from a diagnostic message.
    public static func redacted(_ message: String) -> String {
        var redacted = message
        let replacements: [(pattern: String, replacement: String)] = [
            (#"(?i)\b(stack_access|stack_refresh|access_token|refresh_token|id_token|token|login_code|polling_code|code|state|cmux_auth_state)=([^\s&#,)]+)"#, "$1=<redacted>"),
            (#"(?i)(stack_access|stack_refresh|access_token|refresh_token|id_token|token|login_code|polling_code|code|state|cmux_auth_state)%253[dD]([^\s&#,)]+)"#, "$1%253D<redacted>"),
            (#"(?i)(stack_access|stack_refresh|access_token|refresh_token|id_token|token|login_code|polling_code|code|state|cmux_auth_state)%3[dD]([^\s&#,)]+)"#, "$1%3D<redacted>"),
            (#"(?i)\b(access|refresh)=([^\s,;)]+)"#, "$1=<redacted>"),
            (#"(?i)(access|refresh)%253[dD]([^\s,;)]+)"#, "$1%253D<redacted>"),
            (#"(?i)(access|refresh)%3[dD]([^\s,;)]+)"#, "$1%3D<redacted>"),
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

private func authDebugLogType(for message: String) -> OSLogType {
    let lowercased = message.lowercased()
    if lowercased.contains("failed")
        || lowercased.contains("error")
        || lowercased.contains("invalid")
        || lowercased.contains("status=") {
        return .error
    }
    return .debug
}

#if DEBUG && os(macOS)
private func appendAuthDebugLineToFile(_ line: String, path: String) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    // Re-assert 0600 on pre-existing files (O_CREAT mode only applies at
    // creation) so an old permissive log can't stay world-readable.
    _ = fchmod(fd, 0o600)
    let bytes = Array(line.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard var baseAddress = buffer.baseAddress else { return }
        var remaining = buffer.count
        // Retry short writes/EINTR so a line is never half-appended.
        while remaining > 0 {
            let written = write(fd, baseAddress, remaining)
            if written > 0 {
                baseAddress += written
                remaining -= written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            break
        }
    }
}
#endif
