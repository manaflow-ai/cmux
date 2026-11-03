public import Foundation
import NetworkExtension

/// The Cloud Tunnel's `NETunnelProviderManager`: one saved configuration named "cmux Cloud",
/// found again by its provider bundle identifier's `.tunnel` suffix.
@MainActor
public final class LiveTunnelManager: TunnelManaging {
    /// Why a manager operation could not run.
    public enum ManagerError: LocalizedError {
        case notInstalled

        public var errorDescription: String? {
            String(
                localized: "cloudTunnel.error.notInstalled",
                defaultValue: "The Cloud Tunnel's VPN configuration is missing.",
                bundle: .module
            )
        }
    }

    private var manager: NETunnelProviderManager?

    public init() {}

    public func loadSaved() async throws -> Bool {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier?.hasSuffix(".tunnel") == true
        }
        return manager != nil
    }

    public func install(_ configuration: CloudTunnelConfiguration, providerBundleIdentifier: String) async throws {
        let manager = manager ?? NETunnelProviderManager()
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = providerBundleIdentifier
        tunnel.serverAddress = configuration.endpointHost
        tunnel.providerConfiguration = CloudTunnelProviderConfiguration(wgQuick: configuration.wgQuick).dictionary
        tunnel.disconnectOnSleep = false
        manager.protocolConfiguration = tunnel
        manager.localizedDescription = "cmux Cloud"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        // A saved manager must be reloaded before it can start.
        try await manager.loadFromPreferences()
        self.manager = manager
    }

    public func start() throws {
        guard let manager else { throw ManagerError.notInstalled }
        try manager.connection.startVPNTunnel()
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    public func remove() async throws {
        if manager == nil { _ = try await loadSaved() }
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

    public func states() -> AsyncStream<CloudTunnelConnectionState> {
        let (stream, continuation) = AsyncStream<CloudTunnelConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        guard let connection = manager?.connection else {
            continuation.finish()
            return stream
        }
        continuation.yield(Self.state(of: connection))
        // task-owner: the stream; ends when its consumer cancels.
        let watch = Task { @MainActor in
            let changes = NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection)
            // The observer registers on the first `next()`, after a start() the caller may already
            // have made: read the status again here, with no suspension before that `next()`, so a
            // change between the two is not lost.
            continuation.yield(Self.state(of: connection))
            for await _ in changes {
                continuation.yield(Self.state(of: connection))
            }
        }
        continuation.onTermination = { _ in watch.cancel() }
        return stream
    }

    private static func state(of connection: NEVPNConnection) -> CloudTunnelConnectionState {
        switch connection.status {
        case .connecting: .connecting
        case .connected: .connected(since: connection.connectedDate)
        case .reasserting: .reasserting
        case .disconnecting: .disconnecting
        case .invalid: .invalid
        case .disconnected: .disconnected
        @unknown default: .disconnected
        }
    }
}
