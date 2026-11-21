/// Builds the retry loop that keeps a Cloud VM terminal attached.
///
/// The loop runs a caller-defined `cmux_freestyle_attach` shell function and
/// starts it again while it exits retryable (254 or 255), up to the reconnect
/// budget, waiting between attempts. The CLI, a live workspace and a restored
/// session each build it with their own attach command, so the budget and the
/// wait are read here once. They used to be passed to `[` and `sleep` as given
/// (#10419): an oversized limit made the comparison fail on every retry, and a
/// delay `sleep` rejects made the loop retry without waiting.
public struct CloudVMAttachRetryLoopScriptBuilder: Sendable {
    private let budget: SSHReconnectBudget

    /// Creates a Cloud VM attach retry-loop builder.
    ///
    /// - Parameter budget: The reconnect settings' names, defaults and ceilings.
    public init(budget: SSHReconnectBudget = SSHReconnectBudget()) {
        self.budget = budget
    }

    /// Lines that resolve the reconnect settings, before the attach function.
    ///
    /// The exported reconnect variables keep the values the caller's
    /// environment gave, with the loop's own defaults, because the attach
    /// command reads and normalizes them itself. The attach command's own
    /// retry reads its `CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_*` defaults as
    /// given, with no ceiling and no delay check, so those come from the
    /// normalized copies unless the caller set them explicitly. The loop
    /// reads only the normalized copies.
    public var configurationLines: [String] {
        [
            "CMUX_SSH_RECONNECT_LIMIT=\"${CMUX_SSH_RECONNECT_LIMIT:-\(budget.maximumLimit)}\"",
            "CMUX_SSH_RECONNECT_DELAY_SECONDS=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-\(budget.defaultDelaySeconds)}\"",
            "export CMUX_SSH_RECONNECT_LIMIT CMUX_SSH_RECONNECT_DELAY_SECONDS",
        ]
            + budget.limitNormalizationShellLines(
                variable: "cmux_freestyle_reconnect_limit",
                fallback: budget.maximumLimit,
                acceptsZero: true
            )
            + budget.delayNormalizationShellLines(
                variable: "cmux_freestyle_reconnect_delay",
                maximumVariable: "cmux_freestyle_reconnect_max_delay",
                // This loop waits the same delay every time, with no backoff to cap, so a
                // long delay someone chose is kept up to the ceiling rather than cut to 30s.
                defaultMaximum: budget.maximumLimit
            )
            + [
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$cmux_freestyle_reconnect_limit}\"",
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$cmux_freestyle_reconnect_delay}\"",
                "export CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
            ]
    }

    /// The loop itself, after the caller has defined `cmux_freestyle_attach`.
    public var retryLoopLines: [String] {
        [
            "cmux_freestyle_retry=0",
            "while :; do",
            "  if [ \"$cmux_freestyle_retry\" -gt 0 ]; then",
            "    export CMUX_CLOUD_RECONNECT_ATTEMPT=\"$cmux_freestyle_retry\"",
            "  else",
            "    unset CMUX_CLOUD_RECONNECT_ATTEMPT",
            "  fi",
            "  cmux_freestyle_attach",
            "  cmux_freestyle_status=$?",
            "  case \"$cmux_freestyle_status\" in 254|255) ;; *) exit \"$cmux_freestyle_status\" ;; esac",
            "  if [ \"$cmux_freestyle_retry\" -ge \"$cmux_freestyle_reconnect_limit\" ]; then exit \"$cmux_freestyle_status\"; fi",
            "  cmux_freestyle_retry=$((cmux_freestyle_retry + 1))",
            "  sleep \"$cmux_freestyle_reconnect_delay\"",
            "done",
        ]
    }
}
