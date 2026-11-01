/// Single source of truth for the persistent SSH reconnect budget.
///
/// `CMUX_SSH_RECONNECT_LIMIT` is read by generated shell supervisors in
/// several entrypoints. Each used to hard-code its own numbers, so one name
/// carried a 20-attempt ceiling in the attach supervisor and an 86400 default
/// in the freestyle supervisors. Both sides now read these constants.
public struct SSHReconnectBudget: Sendable {
    /// Environment variable that carries an operator-chosen reconnect budget.
    public let limitEnvironmentName: String

    /// Attempts used when the variable is unset or carries unusable text.
    ///
    /// Failing closed to a small finite budget is deliberate: a persisted
    /// launcher that predates the retry policy, or a typo, must not leave a
    /// corrupt or permanently unavailable daemon spinning forever in a pane.
    public let fallbackLimit: Int

    /// Largest reconnect budget an operator can ask for.
    ///
    /// This is also what the freestyle supervisors default to, so the largest
    /// value an operator may request matches the largest value the app itself
    /// requests. Keeping it finite preserves the fail-closed property above;
    /// at the capped 30s backoff, 86400 attempts is a supervisor that gives up
    /// only after the host has been gone for weeks.
    public let maximumLimit: Int

    /// Environment variable that carries the wait between reconnect attempts, in seconds.
    public let delayEnvironmentName: String

    /// Environment variable that caps ``delayEnvironmentName`` and any backoff built on it.
    public let maximumDelayEnvironmentName: String

    /// Wait used when the delay variable is unset or unusable.
    public let defaultDelaySeconds: Int

    /// Cap used when the maximum-delay variable is unset or unusable.
    public let defaultMaximumDelaySeconds: Int

    /// Creates the reconnect budget used by generated SSH supervisor scripts.
    ///
    /// - Parameters:
    ///   - limitEnvironmentName: Environment variable that overrides the reconnect-attempt limit.
    ///   - fallbackLimit: Attempt limit used when the override is absent or invalid.
    ///   - maximumLimit: Largest accepted attempt limit and delay cap.
    ///   - delayEnvironmentName: Environment variable that overrides the reconnect delay.
    ///   - maximumDelayEnvironmentName: Environment variable that overrides the reconnect-delay cap.
    ///   - defaultDelaySeconds: Delay used when its override is absent or invalid.
    ///   - defaultMaximumDelaySeconds: Delay cap used when its override is absent or invalid.
    public init(
        limitEnvironmentName: String = "CMUX_SSH_RECONNECT_LIMIT",
        fallbackLimit: Int = 20,
        maximumLimit: Int = 86400,
        delayEnvironmentName: String = "CMUX_SSH_RECONNECT_DELAY_SECONDS",
        maximumDelayEnvironmentName: String = "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS",
        defaultDelaySeconds: Int = 2,
        defaultMaximumDelaySeconds: Int = 30
    ) {
        self.limitEnvironmentName = limitEnvironmentName
        self.fallbackLimit = fallbackLimit
        self.maximumLimit = maximumLimit
        self.delayEnvironmentName = delayEnvironmentName
        self.maximumDelayEnvironmentName = maximumDelayEnvironmentName
        self.defaultDelaySeconds = defaultDelaySeconds
        self.defaultMaximumDelaySeconds = defaultMaximumDelaySeconds
    }

    /// Shell lines that resolve ``limitEnvironmentName`` into `variable`.
    ///
    /// A value of 1...``maximumLimit`` is honored, after leading zeros are
    /// stripped. Anything else — non-digits, empty, zero, or a count above the
    /// ceiling — falls back to `fallback` or the ceiling and prints one line to
    /// stderr naming the value it rejected and the value it used. The oversized
    /// case is length-tested before it is compared numerically, because a value
    /// with more digits than the shell's integer range makes `[ … -gt … ]`
    /// error out instead of answering.
    ///
    /// - Parameters:
    ///   - variable: Shell variable that receives the resolved budget. The
    ///     generator also writes `\(variable)_requested` and
    ///     `\(variable)_rejected`.
    ///   - fallback: Budget used when the supplied value is unusable.
    ///   - acceptsZero: Whether `0` is a budget (one attempt, no retry) rather
    ///     than an unusable value. The Cloud VM attach loop has always read it
    ///     that way.
    /// - Returns: POSIX `/bin/sh` lines.
    public func limitNormalizationShellLines(
        variable: String,
        fallback: Int? = nil,
        acceptsZero: Bool = false
    ) -> [String] {
        let fallback = fallback ?? fallbackLimit
        let ceilingDigits = String(maximumLimit).count
        let zeroBranch = acceptsZero ? ":" : "\(variable)_rejected=1; \(variable)=\(fallback)"
        return [
            "\(variable)=\"${\(limitEnvironmentName):-\(fallback)}\"",
            "\(variable)_requested=\"$\(variable)\"",
            "\(variable)_rejected=0",
            "case \"$\(variable)\" in ''|*[!0-9]*) \(variable)_rejected=1; \(variable)=\(fallback) ;; *) "
                + "while [ \"${\(variable)#0}\" != \"$\(variable)\" ] && [ \"$\(variable)\" != 0 ]; do "
                + "\(variable)=\"${\(variable)#0}\"; done; "
                + "if [ \"$\(variable)\" = 0 ]; then \(zeroBranch); "
                + "elif [ \"${#\(variable)}\" -gt \(ceilingDigits) ] || [ \"$\(variable)\" -gt \(maximumLimit) ]; then "
                + "\(variable)_rejected=1; \(variable)=\(maximumLimit); fi ;; esac",
            "if [ \"$\(variable)_rejected\" = 1 ]; then printf "
                + "'[cmux] \(limitEnvironmentName)=%s is not an attempt count in 1-\(maximumLimit); using %s.\\n' "
                + "\"$\(variable)_requested\" \"$\(variable)\" >&2 || true; fi",
        ]
    }

    /// Shell lines that resolve ``delayEnvironmentName`` and
    /// ``maximumDelayEnvironmentName`` into `variable` and `maximumVariable`.
    ///
    /// Each takes a whole number of seconds without leading zeros; anything
    /// else, including `0`, falls back to its default, because `sleep` rejects
    /// some of those values at once and the loop would then retry with no wait.
    /// A delay that was set but falls back prints one line to stderr saying so.
    /// The cap is held to ``maximumLimit`` seconds and the delay to the cap. Both
    /// are length-tested before they are compared, because a value with more
    /// digits than the shell's integer range makes `[ … -gt … ]` error out
    /// instead of answering.
    ///
    /// - Parameters:
    ///   - variable: Shell variable that receives the delay.
    ///   - maximumVariable: Shell variable that receives the cap.
    ///   - defaultMaximum: Cap used when ``maximumDelayEnvironmentName`` is
    ///     unset or unusable; ``defaultMaximumDelaySeconds`` when nil.
    /// - Returns: POSIX `/bin/sh` lines.
    public func delayNormalizationShellLines(
        variable: String,
        maximumVariable: String,
        defaultMaximum: Int? = nil
    ) -> [String] {
        let ceilingDigits = String(maximumLimit).count
        let defaultMaximum = defaultMaximum ?? defaultMaximumDelaySeconds
        let invalidDelayWarning = CmuxConfigValidationLocalization().format(
            "ssh.reconnect.delay.invalid",
            defaultValue: "[cmux] %@=%%s is not a whole number of seconds; using %lld.\n",
            delayEnvironmentName,
            defaultDelaySeconds
        )
        return [
            "\(variable)=\"${\(delayEnvironmentName):-\(defaultDelaySeconds)}\"",
            "case \"$\(variable)\" in ''|*[!0-9]*|0*) "
                + "printf \(invalidDelayWarning.remoteCommandShellQuoted) "
                + "\"$\(variable)\" >&2 || true; \(variable)=\(defaultDelaySeconds) ;; esac",
            "\(maximumVariable)=\"${\(maximumDelayEnvironmentName):-\(defaultMaximum)}\"",
            "case \"$\(maximumVariable)\" in ''|*[!0-9]*|0*) \(maximumVariable)=\(defaultMaximum) ;; esac",
            "if [ \"${#\(maximumVariable)}\" -gt \(ceilingDigits) ] || [ \"$\(maximumVariable)\" -gt \(maximumLimit) ]; then "
                + "\(maximumVariable)=\(maximumLimit); fi",
            "if [ \"${#\(variable)}\" -gt \"${#\(maximumVariable)}\" ] || [ \"$\(variable)\" -gt \"$\(maximumVariable)\" ]; then "
                + "\(variable)=\"$\(maximumVariable)\"; fi",
        ]
    }
}
