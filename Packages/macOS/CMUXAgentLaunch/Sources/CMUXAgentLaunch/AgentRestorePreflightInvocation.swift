import Foundation

/// A shell-free subprocess invocation run before the restored process.
public struct AgentRestorePreflightInvocation: Equatable, Sendable {
    /// The executable token from ``arguments``.
    public let executable: String
    /// Process arguments, including `argv[0]`.
    public let arguments: [String]
    /// Environment passed to the preflight process.
    public let environment: [String: String]

    /// Creates a preflight invocation when `arguments` contains `argv[0]`.
    ///
    /// - Parameters:
    ///   - arguments: Process arguments beginning with the executable token.
    ///   - environment: The complete environment for the preflight process.
    /// - Returns: `nil` when `arguments` is empty.
    public init?(arguments: [String], environment: [String: String]) {
        guard let executable = arguments.first else { return nil }
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Bounds how long a restore waits for its preflight invocation to finish.
///
/// The restore command runs the preflight before `execve`, so the budget below
/// is the product-visible ceiling on "provider setup" before restore reports
/// that setup took too long.
public enum AgentRestorePreflightTimeout {
    /// Ceiling applied to one preflight invocation.
    public static let defaultSeconds: Double = 10

    /// Environment key that replaces ``defaultSeconds``.
    ///
    /// A caller that drives restore non-interactively — a harness, or a
    /// supervisor that retries on its own schedule — bounds the wait here
    /// instead of holding the terminal for the full default window.
    public static let environmentKey = "CMUX_RESTORE_PREFLIGHT_TIMEOUT_SECONDS"

    /// Resolves the preflight budget for `environment`.
    ///
    /// - Parameter environment: Process environment to read the override from.
    /// - Returns: The override when it parses to a finite positive number of
    ///   seconds no greater than the default, otherwise ``defaultSeconds``.
    public static func seconds(environment: [String: String]) -> Double {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = Double(raw),
            value.isFinite,
            value > 0 else {
            return defaultSeconds
        }
        return min(value, defaultSeconds)
    }
}
