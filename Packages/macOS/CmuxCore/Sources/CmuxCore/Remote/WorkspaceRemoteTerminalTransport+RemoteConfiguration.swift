public import CmuxFoundation
internal import Foundation

/// The protocol used by a remote workspace's interactive terminal.
///
/// CmuxCore exposes the shared foundation value as part of its remote-workspace
/// API so callers do not need to import both modules to configure a transport.
public typealias WorkspaceRemoteTerminalTransport = CmuxFoundation.WorkspaceRemoteTerminalTransport

extension WorkspaceRemoteTerminalTransport {
    /// Parses a socket remote-configuration value, defaulting an absent value to SSH.
    ///
    /// - Parameter remoteConfigurationValue: The optional `terminal_transport` wire value.
    public init?(remoteConfigurationValue: String?) {
        let normalized = remoteConfigurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized?.isEmpty != false {
            self = .ssh
        } else {
            self.init(rawValue: normalized ?? "")
        }
    }

    /// Whether this terminal transport is available for the supplied management configuration.
    ///
    /// Mosh currently requires normal SSH daemon bootstrap; WebSocket and pre-baked
    /// cloud-daemon workspaces retain their existing terminal implementations.
    ///
    /// - Parameters:
    ///   - managementTransport: The daemon/control transport.
    ///   - skipDaemonBootstrap: Whether the remote daemon is pre-baked rather than SSH-bootstrapped.
    /// - Returns: `true` when the terminal/management transport pairing is supported.
    public func isSupportedForRemoteConfiguration(
        managementTransport: WorkspaceRemoteTransport,
        skipDaemonBootstrap: Bool
    ) -> Bool {
        self == .ssh || (managementTransport == .ssh && !skipDaemonBootstrap)
    }
}
