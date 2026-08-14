internal import Foundation

/// The protocol used by a remote workspace's interactive terminal.
///
/// This is intentionally separate from the workspace control transport. A
/// Mosh terminal still uses SSH for daemon bootstrap, relay traffic, uploads,
/// proxying, and capability probes.
public enum WorkspaceRemoteTerminalTransport: String, Codable, Equatable, Sendable {
    /// Run the interactive terminal over SSH.
    case ssh

    /// Run the interactive terminal over Mosh while retaining SSH for control traffic.
    case mosh

    /// Parses a case-insensitive CLI transport value.
    ///
    /// - Parameter value: The value supplied to `cmux ssh --transport`.
    public init?(cliValue value: String) {
        self.init(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
