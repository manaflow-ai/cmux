import Foundation

/// The NetworkExtension side of the tunnel, behind a seam so
/// ``CloudTunnelCoordinator`` can be tested with a fake.
///
/// ``NetworkExtensionTunnelController`` is the real implementation:
/// `OSSystemExtensionRequest` for activation, `NETunnelProviderManager` for the
/// VPN configuration, `NEVPNConnection` for start/stop and status.
protocol CloudTunnelControlling: Sendable {
    /// Every `NEVPNStatus` change for this app's tunnel, as it happens.
    var statusUpdates: AsyncStream<CloudTunnelLinkStatus> { get }

    func currentStatus() async -> CloudTunnelLinkStatus

    /// Activate the system extension if needed and save the VPN configuration.
    /// Idempotent. `onNeedsUserApproval` fires when macOS is waiting for the
    /// user to allow the extension in System Settings; the call keeps waiting
    /// for that approval, so callers bound it themselves.
    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws

    /// Ask the system to start the tunnel. Returns once the request is
    /// accepted; readiness arrives through ``statusUpdates``.
    func start() async throws

    /// Ask the system to stop the tunnel. Completion arrives through
    /// ``statusUpdates`` as `.disconnected`.
    func stop() async throws

    /// Stop the tunnel and delete the VPN configuration (unenroll).
    func remove() async throws

    /// Synchronous best-effort stop for `applicationWillTerminate`, where no
    /// async work is guaranteed to run. Main thread only.
    nonisolated func stopForTermination()
}

/// What the app hands the system when it saves the VPN configuration.
