/// A marker for the optional system-wide Cloud VPN warning.
public struct CloudPortsVPNWarning: Equatable, Sendable {
    /// Creates the warning marker.
    public init() {}

    /// Returns a warning only when the tunnel is explicitly known to be off.
    ///
    /// An absent status and every transitional, connected, or failed state are
    /// preserved as non-warning outcomes so the UI never treats uncertainty as
    /// a disconnected VPN.
    ///
    /// - Parameter tunnelState: The latest optional system tunnel state.
    /// - Returns: A warning marker for ``CloudTunnelState/off``; otherwise `nil`.
    public static func projection(tunnelState: CloudTunnelState?) -> Self? {
        guard tunnelState == .off else { return nil }
        return Self()
    }
}
