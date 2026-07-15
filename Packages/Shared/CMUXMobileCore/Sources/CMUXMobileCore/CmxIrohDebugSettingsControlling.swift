/// Debug-only Iroh controls exposed by a host composition root.
@MainActor
public protocol CmxIrohDebugSettingsControlling: AnyObject {
    /// Restarts the host with direct-path activation enabled or disabled.
    ///
    /// - Parameter enabled: `true` to keep authenticated traffic on relay paths.
    func setIrohDebugRelayOnly(_ enabled: Bool) async throws
}
