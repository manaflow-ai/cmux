import Foundation

/// How a remote terminal's process ended, from the daemon's durable exit
/// receipt: the terminal snapshot's `exit` object (`{outcome, exited_at,
/// revision}`) or a `terminal.wait_exit` answer (`{state: "exited", outcome,
/// exited_at}`). `outcome` is `{kind: "exit", code}`, `{kind: "signal",
/// signal, core_dumped}` or `{kind: "unknown", reason}`.
public struct SurfaceTerminalExit: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case exit
        case signal
        case unknown
    }

    public var kind: Kind
    /// The process exit code for `.exit`.
    public var code: Int?
    /// The terminating signal number for `.signal`.
    public var signal: Int?
    /// The daemon's explanation for `.unknown`.
    public var reason: String?
    /// Milliseconds since 1970 when the daemon latched the exit.
    public var exitedAtMilliseconds: Int64?

    public init(kind: Kind, code: Int? = nil, signal: Int? = nil, reason: String? = nil, exitedAtMilliseconds: Int64? = nil) {
        self.kind = kind
        self.code = code
        self.signal = signal
        self.reason = reason
        self.exitedAtMilliseconds = exitedAtMilliseconds
    }

    /// Anything but a clean `exit 0`: a non-zero code, a signal, or an
    /// outcome the daemon could not observe.
    public var isFailure: Bool {
        switch kind {
        case .exit: return code != 0
        case .signal, .unknown: return true
        }
    }

    public var exitedAt: Date? {
        exitedAtMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Parses an `exit` object or a `wait_exit` answer. Nil when the value
    /// carries no outcome.
    public init?(receipt value: Any?) {
        guard let object = value as? [String: Any],
              let outcome = object["outcome"] as? [String: Any] else { return nil }
        let kind = (outcome["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .unknown
        self.init(
            kind: kind,
            code: Self.integer(outcome["code"]),
            signal: Self.integer(outcome["signal"]),
            reason: (outcome["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            exitedAtMilliseconds: Self.integer(object["exited_at"]).map(Int64.init)
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(exactly: number) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
