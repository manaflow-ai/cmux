import Foundation

/// Why a captured agent launch carries no trustworthy argv.
///
/// Stored next to the capture verdict on `AgentLaunchCommand`, so a record that
/// says "rejected" also says what it was rejected on. The values are stable
/// tokens meant to be grepped, diffed and compared across records, never a
/// human sentence that changes shape per call site.
///
/// This is a `RawRepresentable` string rather than an `enum` because hook
/// stores are read and rewritten by whichever cmux build runs next. A token
/// written by a newer build has to decode in an older one and survive being
/// written back: an `enum` would either throw on the unknown token, taking the
/// whole session record down with it, or coerce it to a fallback case the way
/// `AgentHibernationLifecycleState` does and silently rewrite the store with
/// the wrong reason.
public struct AgentLaunchCaptureRejectionReason: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    /// Wraps a stored token, including one this build does not know.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The `CMUX_AGENT_LAUNCH_*` capture describes a different agent than the
    /// hook it reached. That environment leaks into every descendant process,
    /// so an agent started inside another agent's session inherits the
    /// ancestor's launch capture; replaying it would run the wrong binary.
    public static let launcherDoesNotDescribeKind = Self(rawValue: "launcherDoesNotDescribeKind")

    /// The PID fallback resolved to a process that does not describe this agent
    /// kind (an unrelated parent, a test host, the cmux app executable).
    public static let nativeProcessDoesNotDescribeKind = Self(rawValue: "nativeProcessDoesNotDescribeKind")

    /// The PID fallback resolved to a shell dispatcher (`sh -c …`, `zsh -lc …`),
    /// typically the hook's own dispatch shell rather than the agent.
    public static let argvLooksLikeShellWrapper = Self(rawValue: "argvLooksLikeShellWrapper")

    /// No argv was available to judge: no cmux launch capture in the
    /// environment, and no readable argv for the hook's PID (unresolved, or
    /// already exited).
    public static let argvUnavailable = Self(rawValue: "argvUnavailable")

    /// An argv was captured and trusted, but `AgentLaunchSanitizer` judged the
    /// invocation non-restorable (a one-shot subcommand such as `codex exec`, a
    /// rejected option, a wrapper launcher that cannot be replayed). This is
    /// the ground behind a stored `source: "rejected"`.
    public static let sanitizerRejectedArgv = Self(rawValue: "sanitizerRejectedArgv")

    /// The ground a record names when a hook had two argv candidates and
    /// discarded both: the `CMUX_AGENT_LAUNCH_*` capture cmux wrote at launch,
    /// and the argv read back from the hook's PID.
    ///
    /// The cmux capture wins. Not because it comes first, but because the
    /// fallback's ground is frequently an artefact of how the hook itself was
    /// dispatched — hooks run under `sh -c …`, so its argv reads as a shell
    /// wrapper for reasons that have nothing to do with the agent. Letting that
    /// override the capture verdict would systematically hide
    /// `launcherDoesNotDescribeKind`, the ancestor-leak case this field exists
    /// to expose, behind a detail of cmux's own plumbing. The fallback speaks
    /// only when there was no cmux capture to reject.
    ///
    /// - Parameters:
    ///   - cmuxCapture: The ground the `CMUX_AGENT_LAUNCH_*` capture was discarded on, if it was.
    ///   - processFallback: The ground the PID-derived argv was discarded on, if it was.
    /// - Returns: The ground to store, defaulting to `argvUnavailable` when neither candidate existed.
    public static func recorded(
        cmuxCapture: Self?,
        processFallback: Self?
    ) -> Self {
        cmuxCapture ?? processFallback ?? .argvUnavailable
    }
}
