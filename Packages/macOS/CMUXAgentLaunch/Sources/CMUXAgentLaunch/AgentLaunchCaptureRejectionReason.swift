import Foundation

/// Why a captured agent launch carries no trustworthy argv.
///
/// Stored next to the capture verdict on `AgentLaunchCommand`, so a record that
/// says "rejected" also says what it was rejected on. The values are stable
/// tokens meant to be grepped, diffed and compared across records, never a
/// human sentence that changes shape per call site.
///
/// This is a `RawRepresentable` string rather than an `enum` because hook
/// stores are read and rewritten by cmux builds that implement this field. A
/// token written by a newer build has to decode in an older build that knows
/// the field but not the token and survive being written back: an `enum` would
/// either throw on that unknown token, taking the whole session record down
/// with it, or coerce it to a fallback case the way
/// `AgentHibernationLifecycleState` does and silently rewrite the store with
/// the wrong reason. A build from before this field necessarily drops the
/// unknown key when it rewrites a record; that downgrade boundary has no
/// unknown-key passthrough layer and is outside this type's guarantee.
public struct AgentLaunchCaptureRejectionReason: RawRepresentable, Codable, Hashable, Sendable {
    /// The lossless machine-readable token stored alongside a launch verdict.
    public let rawValue: String

    /// Wraps a stored token, including one this build does not know.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes the stable token written by the hook store.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    /// Encodes the stable token without changing its wire representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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

    /// A launch-capture value was present for a trusted launcher, but its
    /// base64/NUL-separated payload could not be decoded into argv.
    public static let argvDecodeFailed = Self(rawValue: "argvDecodeFailed")

    /// An argv was captured and trusted, but `AgentLaunchSanitizer` judged the
    /// invocation non-restorable (a one-shot subcommand such as `codex exec`, a
    /// rejected option, a wrapper launcher that cannot be replayed). This is
    /// the ground behind a stored `source: "rejected"`.
    public static let sanitizerRejectedArgv = Self(rawValue: "sanitizerRejectedArgv")

    /// Chooses the ground a record names when a hook had two argv candidates and
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
    /// When both are absent, the initializer stores ``argvUnavailable``.
    public init(
        recordedFrom cmuxCapture: Self?,
        processFallback: Self?
    ) {
        self = cmuxCapture ?? processFallback ?? .argvUnavailable
    }
}
