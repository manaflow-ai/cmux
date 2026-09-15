#if os(iOS)
import Foundation
import NetworkExtension
import OSLog

/// The iOS preference store and live VPN status are authoritative.
@MainActor
public final class CloudSystemVPNPreferences: CloudSystemVPNManaging {
    public private(set) var phase: CloudSystemVPNPhase = .off
    public var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)?
    private let providerID: String
    private let keychain: CloudVPNConfigurationKeychain
    private var manager: NETunnelProviderManager?
    private var observation: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.cmux.ios", category: "cloud-system-vpn")

    public init(appBundleIdentifier: String, keychainAccessGroup: String) {
        providerID = appBundleIdentifier + ".tunnel"
        keychain = CloudVPNConfigurationKeychain(
            service: appBundleIdentifier + ".cloud-vpn.config",
            accessGroup: keychainAccessGroup + ".cloud-vpn"
        )
        observation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange).map({ _ in true }) {
                guard !Task.isCancelled else { return }
                self?.publishStatus()
            }
        }
    }

    deinit { observation?.cancel() }

    public func refresh(scope: String) async throws {
        let existing = try await load()
        manager = existing
        if let stored = existing?.protocolConfiguration as? NETunnelProviderProtocol,
           stored.providerConfiguration?["scope"] as? String != scope {
            try await stop(removeConfiguration: true)
        }
        publishStatus()
    }

    public func installAndStart(configuration: String, scope: String) async throws {
        #if targetEnvironment(simulator)
        throw CloudSystemVPNError.unavailable
        #else
        do {
            let existing = try await load()
            let manager = existing ?? NETunnelProviderManager()
            self.manager = manager
            // Re-enabling an already-running VPN must not replace its key.
            if manager.connection.status == .connected {
                let saved = manager.protocolConfiguration as? NETunnelProviderProtocol
                if saved?.providerConfiguration?["scope"] as? String == scope {
                    publishStatus()
                    return
                }
                throw CloudSystemVPNError.configuration
            }
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerID
            proto.serverAddress = "cmux Cloud"
            proto.passwordReference = try keychain.store(configuration)
            proto.providerConfiguration = ["schemaVersion": 1, "scope": scope]
            proto.disconnectOnSleep = false
            proto.includeAllNetworks = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "cmux Cloud"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            // Saving the first VPN configuration is what requests iOS consent.
            log.info("Saving Cloud VPN preferences; iOS owns the consent prompt")
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            log.info("Cloud VPN start requested")
            publishStatus()
        } catch {
            if let typed = error as? CloudSystemVPNError { throw typed }
            let ns = error as NSError
            log.error("Cloud VPN setup failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            if ns.domain == NEVPNErrorDomain && ns.code == NEVPNError.configurationReadWriteFailed.rawValue {
                throw CloudSystemVPNError.permissionRequired
            }
            throw CloudSystemVPNError.configuration
        }
        #endif
    }

    public func stop(removeConfiguration: Bool) async throws {
        if manager == nil { manager = try await load() }
        guard let manager else {
            if removeConfiguration { try keychain.remove() }
            publishStatus()
            return
        }
        manager.connection.stopVPNTunnel()
        // Disabled profiles cannot be restarted by Settings after sign-out.
        manager.isEnabled = false
        manager.isOnDemandEnabled = false
        if removeConfiguration {
            try await manager.removeFromPreferences()
            self.manager = nil
            try keychain.remove()
        } else {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        publishStatus()
    }

    private func load() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
    }

    private func publishStatus() {
        switch manager?.connection.status ?? .disconnected {
        case .invalid, .disconnected: phase = .off
        case .connecting, .reasserting: phase = .connecting
        case .connected: phase = .connected
        case .disconnecting: phase = .disconnecting
        @unknown default: phase = .failed(.configuration)
        }
        onPhaseChange?(phase)
    }
}
#endif
