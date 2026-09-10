import Foundation

/// Maps rendered CLI socket failure text onto a stable fingerprint kind so
/// each failure class groups as its own Sentry issue. Without this, every CLI
/// error bridges to the same `cmux_cli.CLIError` NSError (domain + code 1)
/// with system-only frames, and Sentry folds all distinct messages into one
/// mega-issue (https://manaflow.sentry.io/issues/7290136228/).
public struct CLISentryErrorFingerprint: Sendable {
    /// Fingerprint kinds that are expected-but-reportable volume states: worth
    /// one Sentry event per user per throttle window as an app-responsiveness
    /// signal, but not one event per agent hook invocation.
    public static let throttledKinds: Set<String> = ["command-timed-out"]

    public init() {}

    /// Returns a stable kind slug for a known CLI socket failure message, or
    /// `nil` when the message has no dedicated class and should keep Sentry's
    /// default grouping within its stage.
    public func kind(forMessage text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "command timed out" { return "command-timed-out" }
        if t == "not connected" { return "not-connected" }
        if t == "socket read error" { return "socket-read-error" }
        if t.hasPrefix("socket not found at") { return "socket-not-found" }
        if t.hasPrefix("failed to connect to socket") { return "socket-connect-failed" }
        if t.hasPrefix("failed to write to socket") { return "socket-write-failed" }
        if t.hasPrefix("socket closed before") { return "socket-closed-before-reply" }
        return nil
    }
}
