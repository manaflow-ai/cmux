import Foundation
import NetworkExtension
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudTunnelNE")

/// The real ``CloudTunnelControlling``: the bundled network system extension
/// plus one `NETunnelProviderManager` (the VPN configuration macOS shows as
/// "cmux Cloud" in System Settings).
///
/// Main-actor isolated because `applicationWillTerminate` needs a synchronous
/// stop on the already-loaded manager, and NetworkExtension's own callbacks
/// have no isolation guarantees worth building on.
@MainActor
final class NetworkExtensionTunnelController: CloudTunnelControlling {
    private let providerBundleIdentifier: String
    private let activator: SystemExtensionActivator
    private var manager: NETunnelProviderManager?
    /// Reads the existing VPN configuration at launch. Loading preferences is
    /// passive (no prompt, no network), and it is what lets quit, sign-out, and
    /// `cmux vpn down` stop a tunnel the previous app instance left connected
    /// before this instance has used Cloud at all.
    private var initialLoad: Task<Void, Never>?

    init(providerBundleIdentifier: String, activator: SystemExtensionActivator = SystemExtensionActivator()) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.activator = activator
        initialLoad = Task { [weak self] in
            await self?.loadExistingManagerIfNeeded()
        }
    }

    nonisolated var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { continuation in
            let task = Task {
                let notifications = NotificationCenter.default.notifications(named: .NEVPNStatusDidChange)
                for await notification in notifications {
                    guard let connection = notification.object as? NEVPNConnection else { continue }
                    continuation.yield(CloudTunnelLinkStatus(connection.status))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentStatus() async -> CloudTunnelLinkStatus {
        await loadExistingManagerIfNeeded()
        guard let manager else { return .disconnected }
        return CloudTunnelLinkStatus(manager.connection.status)
    }

    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {
        try await activator.activate(identifier: providerBundleIdentifier, onNeedsUserApproval: onNeedsUserApproval)
        let manager = try await loadOrCreateManager()
        let providerProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.serverAddress = configuration.serverAddress
        providerProtocol.providerConfiguration = [
            CloudTunnelProviderConfigurationKeys.wgQuickConfig: configuration.wgQuickConfig,
            CloudTunnelProviderConfigurationKeys.schemaVersion: CloudTunnelProviderConfigurationKeys.currentSchemaVersion,
        ]
        providerProtocol.disconnectOnSleep = false
        manager.protocolConfiguration = providerProtocol
        manager.localizedDescription = configuration.localizedDescription
        manager.isEnabled = true
        // The app decides when the tunnel runs; macOS must never start it on
        // its own because some process resolved a name or touched a network.
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        try await manager.saveToPreferences()
        // NetworkExtension requires a reload after save before the connection
        // object reflects the saved configuration.
        try await manager.loadFromPreferences()
        self.manager = manager
        logger.info("VPN configuration saved for \(self.providerBundleIdentifier, privacy: .public)")
    }

    func start() async throws {
        guard let manager else { throw CloudTunnelError.configurationNotInstalled }
        try manager.connection.startVPNTunnel()
    }

    func stop() async throws {
        await loadExistingManagerIfNeeded()
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
    }

    func remove() async throws {
        await loadExistingManagerIfNeeded()
        if let manager {
            try await manager.removeFromPreferences()
            self.manager = nil
            return
        }
        for candidate in try await NETunnelProviderManager.loadAllFromPreferences() where isOurs(candidate) {
            try await candidate.removeFromPreferences()
        }
    }

    nonisolated func stopForTermination() {
        // applicationWillTerminate runs on the main thread; anything else is a
        // programming error worth trapping on rather than silently skipping.
        MainActor.assumeIsolated {
            manager?.connection.stopVPNTunnel()
        }
    }

    /// Cache this app's existing configuration, if any, without creating one.
    private func loadExistingManagerIfNeeded() async {
        if manager != nil { return }
        if let initialLoad, !Task.isCancelled {
            // Let the launch-time load finish rather than racing a second one.
            self.initialLoad = nil
            _ = await initialLoad.value
            if manager != nil { return }
        }
        guard let existing = try? await NETunnelProviderManager.loadAllFromPreferences() else { return }
        manager = existing.first(where: isOurs)
    }

    /// The app's existing configuration when there is one (each app can only
    /// see its own), otherwise a fresh manager.
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        if let ours = existing.first(where: isOurs) {
            return ours
        }
        if let first = existing.first {
            return first
        }
        return NETunnelProviderManager()
    }

    private func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
    }
}
