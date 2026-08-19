/// The reconnect budget a generated attach loop reads from the environment.
///
/// `CMUX_SSH_RECONNECT_LIMIT` and `CMUX_SSH_RECONNECT_DELAY_SECONDS` are shared
/// by every persistent attach entry point, so a value a user sets for one loop
/// reaches the others too. An instance owns how those two variables are read and
/// how the loop that reads them compares and waits, so the handling cannot drift
/// between the loops that inherit it, and a loop with its own idea of a sensible
/// default constructs the policy with that default rather than restating the
/// reading of the value.
public struct SSHReconnectBudgetShellPolicy: Sendable, Equatable {
    /// The largest retry budget a generated comparison can answer.
    ///
    /// `CMUX_SSH_RECONNECT_LIMIT` is free-form text, and a value too large for
    /// shell arithmetic makes `-ge` fail with `integer expression expected`
    /// instead of answering, which leaves the loop unbounded. The ceiling is a
    /// number of retries no outage reaches before the host comes back.
    public static let maximumConfigurableRetryLimit = 1_000_000

    /// The longest wait between two attempts, in seconds.
    ///
    /// `sleep` rejects an interval it cannot represent, so an oversized delay
    /// makes the loop retry with no wait at all. A day between attempts is
    /// already indistinguishable from never.
    public static let maximumConfigurableDelaySeconds = 86_400

    /// The environment variable holding the retry budget.
    public static let retryLimitVariable = "CMUX_SSH_RECONNECT_LIMIT"

    /// The environment variable holding the delay between attempts.
    public static let delaySecondsVariable = "CMUX_SSH_RECONNECT_DELAY_SECONDS"

    /// The retries the loop takes when the environment does not set a limit.
    public let defaultRetryLimit: Int

    /// The seconds the loop waits between attempts when the environment does
    /// not set a delay.
    public let defaultDelaySeconds: Int

    /// Creates a budget, holding its own defaults to the same ceilings it
    /// holds a configured value to.
    ///
    /// - Parameters:
    ///   - defaultRetryLimit: Retries allowed when the environment is silent.
    ///   - defaultDelaySeconds: Seconds waited when the environment is silent.
    public init(
        defaultRetryLimit: Int = 86_400,
        defaultDelaySeconds: Int = 2
    ) {
        self.defaultRetryLimit = min(max(0, defaultRetryLimit), Self.maximumConfigurableRetryLimit)
        self.defaultDelaySeconds = min(max(0, defaultDelaySeconds), Self.maximumConfigurableDelaySeconds)
    }

    /// Shell lines that resolve and normalize both variables before the loop runs.
    ///
    /// Each value is rejected when it is not a number, capped when it is larger
    /// than the loop can act on, and assigned back to its own variable, so a
    /// loop that exports them hands the normalized values to the processes it
    /// starts as well.
    public var configurationLines: [String] {
        let retryLimit = Self.retryLimitVariable
        let delaySeconds = Self.delaySecondsVariable
        return [
            "\(retryLimit)=\"${\(retryLimit):-\(defaultRetryLimit)}\"",
            // Padding comes off before anything counts digits, because "0000002"
            // is a budget of two retries, not of a seven-digit number of them.
            paddingStrippingLine(variable: retryLimit),
            // A digit count is the only test for "too large" that a shell can run
            // without first turning the value into a number it may not be able to
            // represent, which is the failure being prevented.
            "case \"$\(retryLimit)\" in ''|*[!0-9]*) \(retryLimit)=\(defaultRetryLimit) ;; \(digitPattern(minimumDigits: 7))) \(retryLimit)=\(Self.maximumConfigurableRetryLimit) ;; esac",
            "\(delaySeconds)=\"${\(delaySeconds):-\(defaultDelaySeconds)}\"",
            paddingStrippingLine(variable: delaySeconds),
            "case \"$\(delaySeconds)\" in ''|*[!0-9]*) \(delaySeconds)=\(defaultDelaySeconds) ;; \(digitPattern(minimumDigits: 6))) \(delaySeconds)=\(Self.maximumConfigurableDelaySeconds) ;; esac",
            // The ceiling is five digits, so the values the case above lets
            // through still need comparing, and by now they are small enough to
            // compare safely.
            "if [ \"$\(delaySeconds)\" -gt \(Self.maximumConfigurableDelaySeconds) ]; then \(delaySeconds)=\(Self.maximumConfigurableDelaySeconds); fi",
        ]
    }

    /// The shell command that ends a loop once its retry budget is spent.
    ///
    /// - Parameters:
    ///   - retryCountVariable: The loop's shell variable holding retries taken.
    ///   - statusVariable: The loop's shell variable holding the last attach status.
    /// - Returns: A command that exits with the last status at the budget.
    public func limitReachedCommand(
        retryCountVariable: String,
        statusVariable: String
    ) -> String {
        "if [ \"$\(retryCountVariable)\" -ge \"$\(Self.retryLimitVariable)\" ]; then exit \"$\(statusVariable)\"; fi"
    }

    /// The shell command that waits between two attempts.
    public var delayCommand: String {
        "sleep \"$\(Self.delaySecondsVariable)\""
    }

    /// A line that drops the leading zeros of `variable`, keeping a bare `0`.
    private func paddingStrippingLine(variable: String) -> String {
        "while :; do case \"$\(variable)\" in 0?*) \(variable)=\"${\(variable)#0}\" ;; *) break ;; esac; done"
    }

    /// A `case` pattern matching values of at least `minimumDigits` characters.
    private func digitPattern(minimumDigits: Int) -> String {
        String(repeating: "?", count: minimumDigits) + "*"
    }
}
