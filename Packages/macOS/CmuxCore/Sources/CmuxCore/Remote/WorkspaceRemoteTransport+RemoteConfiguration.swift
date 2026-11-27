internal import Foundation

extension WorkspaceRemoteTransport {
    /// Parses a socket remote-configuration value, defaulting absent or unknown values to SSH.
    ///
    /// - Parameter remoteConfigurationValue: The optional `transport` wire value.
    public init(remoteConfigurationValue: String?) {
        let normalized = remoteConfigurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = Self(rawValue: normalized ?? "") ?? .ssh
    }
}
