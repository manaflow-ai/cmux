import Foundation

/// Describes which command-line entrypoint started the agent process.
public enum LaunchArgvKind: String, Hashable, Sendable {
    /// A new interactive session launch.
    case new
    /// A resume invocation for an existing session.
    case resume
    /// A non-interactive execution invocation.
    case exec
}
