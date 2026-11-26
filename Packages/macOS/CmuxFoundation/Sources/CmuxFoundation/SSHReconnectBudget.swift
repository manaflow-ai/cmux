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

    /// Environment variable that carries the wait between reconnect attempts.
    public let delayEnvironmentName: String

    /// Seconds waited when the delay variable is unset or unusable.
    public let fallbackDelaySeconds: Int

    /// Longest wait an operator can ask for between attempts.
    public let maximumDelaySeconds: Int

    public init(
        limitEnvironmentName: String = "CMUX_SSH_RECONNECT_LIMIT",
        fallbackLimit: Int = 20,
        maximumLimit: Int = 86400,
        delayEnvironmentName: String = "CMUX_SSH_RECONNECT_DELAY_SECONDS",
        fallbackDelaySeconds: Int = 2,
        maximumDelaySeconds: Int = 30
    ) {
        self.limitEnvironmentName = limitEnvironmentName
        self.fallbackLimit = fallbackLimit
        self.maximumLimit = maximumLimit
        self.delayEnvironmentName = delayEnvironmentName
        self.fallbackDelaySeconds = fallbackDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
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
    /// - Returns: POSIX `/bin/sh` lines.
    public func limitNormalizationShellLines(
        variable: String,
        fallback: Int? = nil
    ) -> [String] {
        let fallback = fallback ?? fallbackLimit
        let ceilingDigits = String(maximumLimit).count
        return [
            "\(variable)=\"${\(limitEnvironmentName):-\(fallback)}\"",
            "\(variable)_requested=\"$\(variable)\"",
            "\(variable)_rejected=0",
            "case \"$\(variable)\" in ''|*[!0-9]*) \(variable)_rejected=1; \(variable)=\(fallback) ;; *) "
                + "while [ \"${\(variable)#0}\" != \"$\(variable)\" ] && [ \"$\(variable)\" != 0 ]; do "
                + "\(variable)=\"${\(variable)#0}\"; done; "
                + "if [ \"$\(variable)\" = 0 ]; then \(variable)_rejected=1; \(variable)=\(fallback); "
                + "elif [ \"${#\(variable)}\" -gt \(ceilingDigits) ] || [ \"$\(variable)\" -gt \(maximumLimit) ]; then "
                + "\(variable)_rejected=1; \(variable)=\(maximumLimit); fi ;; esac",
            "if [ \"$\(variable)_rejected\" = 1 ]; then printf "
                + "'[cmux] \(limitEnvironmentName)=%s is not an attempt count in 1-\(maximumLimit); using %s.\\n' "
                + "\"$\(variable)_requested\" \"$\(variable)\" >&2 || true; fi",
        ]
    }

    /// Shell lines that resolve ``delayEnvironmentName`` into `variable`.
    ///
    /// Only digits are a delay. Leading zeros are stripped, zero becomes one
    /// second so a retry never spins without waiting, and anything above
    /// ``maximumDelaySeconds`` (tested by length first, like the limit) is
    /// clamped to it. Non-digit or empty text falls back to
    /// ``fallbackDelaySeconds`` instead of reaching `sleep`, which would fail
    /// immediately and turn the retry loop into a busy loop.
    ///
    /// - Parameter variable: Shell variable that receives the delay.
    /// - Returns: POSIX `/bin/sh` lines.
    public func delayNormalizationShellLines(variable: String) -> [String] {
        let ceilingDigits = String(maximumDelaySeconds).count
        return [
            "\(variable)=\"${\(delayEnvironmentName):-\(fallbackDelaySeconds)}\"",
            "case \"$\(variable)\" in ''|*[!0-9]*) \(variable)=\(fallbackDelaySeconds) ;; *) "
                + "while [ \"${\(variable)#0}\" != \"$\(variable)\" ] && [ \"$\(variable)\" != 0 ]; do "
                + "\(variable)=\"${\(variable)#0}\"; done; "
                + "if [ \"$\(variable)\" = 0 ]; then \(variable)=1; "
                + "elif [ \"${#\(variable)}\" -gt \(ceilingDigits) ] || [ \"$\(variable)\" -gt \(maximumDelaySeconds) ]; then "
                + "\(variable)=\(maximumDelaySeconds); fi ;; esac",
        ]
    }

    /// The Freestyle attach/reconnect loop shared by every launcher that
    /// re-runs `vm-pty-attach` when the connection drops.
    ///
    /// Normalizes the limit (falling back to ``maximumLimit``) and the delay,
    /// exports the normalized values so the child attach sees them, then runs
    /// `attachCommand` until it exits with anything other than 254 or 255, or
    /// the retry budget is spent.
    ///
    /// - Parameter attachCommand: Shell command (usually a function) that
    ///   performs one attach.
    /// - Returns: POSIX `/bin/sh` lines.
    public func attachRetryLoopShellLines(attachCommand: String) -> [String] {
        limitNormalizationShellLines(variable: "cmux_freestyle_reconnect_limit", fallback: maximumLimit)
            + delayNormalizationShellLines(variable: "cmux_freestyle_reconnect_delay")
            + [
                "\(limitEnvironmentName)=\"$cmux_freestyle_reconnect_limit\"",
                "\(delayEnvironmentName)=\"$cmux_freestyle_reconnect_delay\"",
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$\(limitEnvironmentName)}\"",
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$\(delayEnvironmentName)}\"",
                "export \(limitEnvironmentName) \(delayEnvironmentName)",
                "export CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
                "cmux_freestyle_retry=0",
                "while :; do",
                "  if [ \"$cmux_freestyle_retry\" -gt 0 ]; then",
                "    export CMUX_CLOUD_RECONNECT_ATTEMPT=\"$cmux_freestyle_retry\"",
                "  else",
                "    unset CMUX_CLOUD_RECONNECT_ATTEMPT",
                "  fi",
                "  \(attachCommand)",
                "  cmux_freestyle_status=$?",
                "  case \"$cmux_freestyle_status\" in 254|255) ;; *) exit \"$cmux_freestyle_status\" ;; esac",
                "  if [ \"$cmux_freestyle_retry\" -ge \"$\(limitEnvironmentName)\" ]; then exit \"$cmux_freestyle_status\"; fi",
                "  cmux_freestyle_retry=$((cmux_freestyle_retry + 1))",
                "  sleep \"$\(delayEnvironmentName)\"",
                "done",
            ]
    }
}
