#if os(iOS)
import Foundation
import NetworkExtension
import OSLog

/// The Network Extension side of the system VPN. iOS's saved preferences and
/// live connection status are authoritative; this only mirrors them.
@MainActor
public final class CloudSystemVPNPreferences: CloudSystemVPNManaging {
    public private(set) var phase: CloudSystemVPNPhase = .off
    public var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)?

    private let providerBundleIdentifier: String
    private let keychain: CloudVPNConfigurationKeychain
    private var manager: NETunnelProviderManager?
    private var observation: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.cmux.ios", category: "cloud-system-vpn")

    /// The provider configuration's schema; the extension refuses others.
    public static let schemaVersion = 1

    /// - Parameters:
    ///   - providerBundleIdentifier: The packet tunnel extension's bundle id.
    ///   - keychainService: The configuration item's service, unique per app.
    ///   - keychainAccessGroup: The group the app and extension share.
    public init(providerBundleIdentifier: String, keychainService: String, keychainAccessGroup: String?) {
        self.providerBundleIdentifier = providerBundleIdentifier
        keychain = CloudVPNConfigurationKeychain(service: keychainService, accessGroup: keychainAccessGroup)
        observation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange).map({ _ in () }) {
                guard !Task.isCancelled else { return }
                self?.publishStatus()
            }
        }
    }

    isolated deinit { observation?.cancel() }

    public var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

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
        guard isAvailable else { throw CloudSystemVPNError.unavailable }
        do {
            let manager = try await load() ?? NETunnelProviderManager()
            self.manager = manager
            if manager.connection.status == .connected {
                let saved = manager.protocolConfiguration as? NETunnelProviderProtocol
                if saved?.providerConfiguration?["scope"] as? String == scope {
                    publishStatus()
                    return
                }
                throw CloudSystemVPNError.configuration
            }
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleIdentifier
            proto.serverAddress = "cmux Cloud"
            proto.passwordReference = try keychain.store(configuration)
            proto.providerConfiguration = ["schemaVersion": Self.schemaVersion, "scope": scope]
            proto.disconnectOnSleep = false
            proto.includeAllNetworks = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "cmux Cloud"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            // The first save is what asks the user for VPN consent.
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            publishStatus()
        } catch let error as CloudSystemVPNError {
            throw error
        } catch {
            let ns = error as NSError
            log.error("Cloud VPN setup failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            if ns.domain == NEVPNErrorDomain, ns.code == NEVPNError.configurationReadWriteFailed.rawValue {
                throw CloudSystemVPNError.permissionRequired
            }
            throw CloudSystemVPNError.configuration
        }
    }

    /// Requests cancellation of a platform operation that exceeded its
    /// deadline.
    public func cancelPendingOperation() {
        manager?.connection.stopVPNTunnel()
    }

    public func stop(removeConfiguration: Bool) async throws {
        if manager == nil {
            do {
                manager = try await load()
            } catch {
                if removeConfiguration {
                    try? keychain.remove()
                }
                throw error
            }
        }
        guard let manager else {
            if removeConfiguration { try keychain.remove() }
            publishStatus()
            return
        }
        manager.connection.stopVPNTunnel()
        // A disabled profile cannot be restarted from Settings after sign-out.
        manager.isEnabled = false
        manager.isOnDemandEnabled = false
        if removeConfiguration {
            var removalError: Error?
            do {
                try await manager.removeFromPreferences()
            } catch {
                removalError = error
            }
            self.manager = nil
            do {
                try keychain.remove()
            } catch {
                if removalError == nil { removalError = error }
            }
            publishStatus()
            if let removalError { throw removalError }
        } else {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        publishStatus()
    }

    private func load() async throws -> NETunnelProviderManager? {
        guard isAvailable else { return nil }
        return try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
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
