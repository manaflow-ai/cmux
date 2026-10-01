public import Foundation

/// Seconds between `vm.status` polls in `cmux vm wait`.
///
/// `CMUX_VM_WAIT_POLL_SECONDS` lets tests against a mock control socket poll
/// faster than the production cadence. An override may only shorten the
/// cadence, so a bad value can never outlive the command's `--timeout`.
public enum CLIVMWaitPollInterval {
    /// The environment key that overrides the cadence.
    public static let environmentKey = "CMUX_VM_WAIT_POLL_SECONDS"
    /// The production cadence, and the upper bound for an override.
    public static let defaultSeconds: TimeInterval = 3
    /// The smallest override that is honored.
    public static let minimumOverrideSeconds: TimeInterval = 0.01

    /// Resolves the poll interval for a process environment.
    ///
    /// - Parameter environment: The CLI process environment.
    /// - Returns: The override when it is a finite value in
    ///   `minimumOverrideSeconds...defaultSeconds`, otherwise `defaultSeconds`.
    public static func resolve(environment: [String: String]) -> TimeInterval {
        guard let raw = environment[environmentKey],
              let parsed = TimeInterval(raw),
              parsed.isFinite,
              (minimumOverrideSeconds...defaultSeconds).contains(parsed) else {
            return defaultSeconds
        }
        return parsed
    }
}
