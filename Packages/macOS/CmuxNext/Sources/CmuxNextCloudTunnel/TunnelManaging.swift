/// The Cloud Tunnel's saved VPN configuration (`NETunnelProviderManager`). A seam so the
/// controller is tested without NetworkExtension; ``LiveTunnelManager`` is the real one.
@MainActor
public protocol TunnelManaging: AnyObject {
    /// Loads cmux's saved tunnel configuration, if any.
    ///
    /// - Returns: Whether one exists (a previous opt-in saved it).
    func loadSaved() async throws -> Bool
    /// Saves (or replaces) the configuration for the extension `providerBundleIdentifier`.
    func install(_ configuration: CloudTunnelConfiguration, providerBundleIdentifier: String) async throws
    /// Starts the saved configuration.
    func start() throws
    /// Stops the tunnel.
    func stop()
    /// Removes the saved configuration.
    func remove() async throws
    /// The configuration's connection state, now and on every change.
    func states() -> AsyncStream<CloudTunnelConnectionState>
}
