import Foundation

/// The reconnect budget a generated attach loop reads from the environment.
///
/// `CMUX_SSH_RECONNECT_LIMIT` and `CMUX_SSH_RECONNECT_DELAY_SECONDS` are shared
/// by every persistent attach entry point, so a value a user sets for one loop
/// reaches the others too. This type owns how those two variables are read and
/// how the loop that reads them compares and waits, so the handling cannot drift
/// between the loops that inherit it.
public enum SSHReconnectBudgetShellPolicy {
    /// The retries a loop takes when the environment does not set a limit.
    public static let defaultRetryLimit = 86_400

    /// The seconds a loop waits between attempts when the environment does not
    /// set a delay.
    public static let defaultDelaySeconds = 2

    /// The largest retry budget the generated comparison can answer.
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

    /// Shell lines that resolve both variables before the loop runs.
    ///
    /// The values are assigned back to their own variables, so a loop that
    /// exports them hands the resolved values to the processes it starts.
    public static var configurationLines: [String] {
        [
            "\(retryLimitVariable)=\"${\(retryLimitVariable):-\(defaultRetryLimit)}\"",
            "\(delaySecondsVariable)=\"${\(delaySecondsVariable):-\(defaultDelaySeconds)}\"",
        ]
    }

    /// The shell command that ends a loop once its retry budget is spent.
    ///
    /// - Parameters:
    ///   - retryCountVariable: The loop's shell variable holding retries taken.
    ///   - statusVariable: The loop's shell variable holding the last attach status.
    /// - Returns: A command that exits with the last status at the budget.
    public static func limitReachedCommand(
        retryCountVariable: String,
        statusVariable: String
    ) -> String {
        "if [ \"$\(retryCountVariable)\" -ge \"$\(retryLimitVariable)\" ]; then exit \"$\(statusVariable)\"; fi"
    }

    /// The shell command that waits between two attempts.
    public static var delayCommand: String {
        "sleep \"$\(delaySecondsVariable)\""
    }
}
