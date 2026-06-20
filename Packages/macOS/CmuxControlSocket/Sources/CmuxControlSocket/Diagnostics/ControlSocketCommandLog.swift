#if DEBUG
public import Foundation

/// The pure classification and message-formatting layer for the control
/// socket's per-command debug log (`CMUX_DEBUG_SOCKET_COMMAND_LOG`).
///
/// This type owns every decision the legacy `TerminalController` made about the
/// `socket.command.begin`/`socket.command.end` debug lines: whether logging is
/// enabled, how a command line is classified into a protocol + sanitized method
/// token, whether a response counts as an error, and the exact begin/end log
/// strings. It performs no I/O and holds no app state — the caller owns the
/// debug sink (`cmuxDebugLog`) and writes whatever non-`nil` message these
/// methods return, exactly where the legacy code called `debugLogSocketCommand`.
///
/// It is a real value type with constructor-injected configuration, not a
/// static namespace: the environment and slow-command threshold are stored, so
/// tests can inject a fixed environment and the production caller seeds it from
/// `ProcessInfo`. Gated to `#if DEBUG`, matching the legacy block; the begin/end
/// instrumentation never compiles into release builds.
public struct ControlSocketCommandLog: Sendable {
    /// The environment variable that toggles the per-command debug log.
    public static let logEnabledEnvironmentKey = "CMUX_DEBUG_SOCKET_COMMAND_LOG"

    /// The elapsed-time threshold (milliseconds) above which a command is
    /// logged on its end line even when verbose logging is off.
    public static let slowThresholdMs: Double = 500

    private let environment: [String: String]
    private let slowThresholdMs: Double

    /// Creates a command-log classifier.
    /// - Parameters:
    ///   - environment: The process environment consulted for the enable flag.
    ///     Defaults to the live process environment.
    ///   - slowThresholdMs: The slow-command threshold in milliseconds.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        slowThresholdMs: Double = ControlSocketCommandLog.slowThresholdMs
    ) {
        self.environment = environment
        self.slowThresholdMs = slowThresholdMs
    }

    /// Whether verbose per-command logging is enabled by the environment.
    public var isLoggingEnabled: Bool {
        guard let rawValue = environment[Self.logEnabledEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    /// Classifies a raw command line into its protocol and sanitized method.
    /// - Parameter command: The raw client command line.
    /// - Returns: The protocol name (`v1`/`v2`) and sanitized command token.
    public func info(forCommand command: String) -> SocketCommandDebugInfo {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let method = dict["method"] as? String else {
            let commandKey = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            return SocketCommandDebugInfo(protocolName: "v1", commandKey: Self.sanitizedToken(commandKey))
        }
        return SocketCommandDebugInfo(protocolName: "v2", commandKey: Self.sanitizedToken(method))
    }

    /// The `socket.command.begin` line for `info`.
    /// - Parameter info: The classified command info.
    /// - Returns: The begin log message.
    public func beginMessage(for info: SocketCommandDebugInfo) -> String {
        "socket.command.begin proto=\(info.protocolName) method=\(info.commandKey)"
    }

    /// The `socket.command.end` line for a completed command, or `nil` when the
    /// command should not be logged (verbose off, fast, and `ok`).
    /// - Parameters:
    ///   - info: The classified command info.
    ///   - startedAtUptimeNanos: `DispatchTime.now().uptimeNanoseconds` captured
    ///     before the command ran.
    ///   - response: The wire response the command produced.
    ///   - loggingEnabled: Whether verbose logging is enabled (pass the value
    ///     read once at begin time, matching the legacy capture).
    /// - Returns: The end log message to emit, or `nil` to skip.
    public func endMessageIfNeeded(
        info: SocketCommandDebugInfo,
        startedAtUptimeNanos: UInt64,
        response: String,
        loggingEnabled: Bool
    ) -> String? {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtUptimeNanos) / 1_000_000
        let status = Self.status(forResponse: response)
        guard loggingEnabled || elapsedMs >= slowThresholdMs || status != "ok" else {
            return nil
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        return "socket.command.end proto=\(info.protocolName) method=\(info.commandKey) status=\(status) ms=\(elapsedText) bytes=\(response.utf8.count)"
    }

    /// Sanitizes a command/method token for the debug log: keeps an allow-list
    /// of characters, replaces the rest with `_`, caps at 96 characters, and
    /// falls back to `<empty>`.
    /// - Parameter value: The raw token.
    /// - Returns: The sanitized token.
    public static func sanitizedToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    /// Classifies a wire response as `ok` or `error` for the debug log status
    /// field: a `ERROR:`-prefixed v1 line or a v2 JSON object whose top-level
    /// `error`/`ok:false` marks it as an error.
    /// - Parameter response: The wire response.
    /// - Returns: `"error"` or `"ok"`.
    public static func status(forResponse response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return "error"
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if JSONResponseStatusScanner.topLevelStatus(in: prefix) == "error" {
                return "error"
            }
        }
        return "ok"
    }
}
#endif
