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

    public init(
        limitEnvironmentName: String = "CMUX_SSH_RECONNECT_LIMIT",
        fallbackLimit: Int = 20,
        maximumLimit: Int = 86400
    ) {
        self.limitEnvironmentName = limitEnvironmentName
        self.fallbackLimit = fallbackLimit
        self.maximumLimit = maximumLimit
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
}
