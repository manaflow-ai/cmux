internal import Foundation

/// Selects how Mosh discovers the address used for its UDP session.
public enum MoshRemoteIPMode: String, Codable, Equatable, Sendable {
    /// Derive the address from the remote SSH connection when possible.
    case remote

    /// Resolve the destination locally before starting the Mosh server.
    case local

    /// Resolve the address through Mosh's local proxy path.
    case proxy

    /// Parses a case-insensitive command-line value.
    ///
    /// - Parameter value: The value supplied for a Mosh remote-IP mode.
    /// - Returns: The matching mode, or `nil` for an unsupported value.
    public init?(cliValue value: String) {
        self.init(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
