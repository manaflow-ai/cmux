import Foundation
import NetworkExtension
import WireGuardKit
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app.tunnel", category: "PacketTunnelProvider")

private final class CloudTunnelProviderCompletionBox: @unchecked Sendable {
    private let completion: (Error?) -> Void

    /// Stores the NetworkExtension completion at the callback boundary.
    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    /// Delivers one provider error to the original NetworkExtension callback.
    func call(_ error: CloudTunnelProviderError?) {
        completion(error)
    }
}

/// The cmux Cloud tunnel: one WireGuard interface into the user's private Cloud
/// VM network, run as a macOS network system extension.
///
/// The cmux app owns enrollment, the keypair, and the VPN configuration
/// (`NETunnelProviderManager`); this provider only turns the saved
/// configuration into a live interface. It reads the completed wg-quick config
/// from `providerConfiguration` (see ``CloudTunnelProviderConfigurationKeys``),
/// hands it to WireGuardKit, and reports runtime state back on request.
///
/// Nothing here decides *when* the tunnel runs. The app starts it on demand
/// when the user opens a Cloud machine and stops it when no Cloud sessions
/// remain; the system never auto-connects it (no on-demand rules are set).
///
/// Entitlements (`packet-tunnel-provider-systemextension`, App Sandbox, the
/// team App Group) are applied by `scripts/sign-cmux-bundle.sh` from
/// `TunnelExtension/cmuxTunnelExtension.{release,nightly}.entitlements` at
/// release signing time, exactly as the app's own restricted entitlements are.
/// Xcode-signed Debug builds carry none: they cannot load the extension anyway
/// without a provisioning profile, and Xcode refuses to ad-hoc sign restricted
/// entitlements.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let startGate = CloudTunnelProviderStartGate()
    private let runtimeConfigurationRedactor = CloudTunnelRuntimeConfigurationRedactor()
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        switch level {
        case .verbose:
            logger.debug("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }

    /// Admits one NetworkExtension start and coalesces callbacks replayed by macOS.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("startTunnel requested by \(options == nil ? "the system" : "the cmux app", privacy: .public)")
        let completionBox = CloudTunnelProviderCompletionBox(completionHandler)
        Task { [weak self, completionBox] in
            guard let self else { return }
            let request = await startGate.request { error in
                completionBox.call(error)
            }
            switch request {
            case .begin(let generation):
                logger.info("startTunnel beginning generation \(generation, privacy: .public)")
                self.startTunnel()
            case .coalesced(let generation, let waiterCount):
                logger.info("startTunnel coalesced generation \(generation, privacy: .public), callbacks \(waiterCount, privacy: .public)")
            case .alreadyStarted(let generation):
                logger.info("startTunnel replay accepted for running generation \(generation, privacy: .public)")
                completionBox.call(nil)
            }
        }
    }

    /// Starts WireGuard for the generation admitted by ``startGate``.
    private func startTunnel() {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = providerProtocol.providerConfiguration,
              let wgQuickConfig = providerConfiguration[CloudTunnelProviderConfigurationKeys.wgQuickConfig] as? String,
              !wgQuickConfig.isEmpty else {
            logger.error("startTunnel: the saved VPN configuration carries no wg-quick config")
            finishStart(error: .missingConfiguration)
            return
        }
        let schemaVersion = providerConfiguration[CloudTunnelProviderConfigurationKeys.schemaVersion] as? Int
        guard schemaVersion == CloudTunnelProviderConfigurationKeys.currentSchemaVersion else {
            logger.error("startTunnel: unsupported provider configuration schema \(schemaVersion.map(String.init) ?? "nil", privacy: .public)")
            finishStart(error: .unsupportedSchema)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "cmux Cloud")
        } catch {
            // Parse errors carry the offending value; the private key is one of
            // them, so log only which rule failed.
            logger.error("startTunnel: wg-quick config rejected (\(Self.caseName(of: error), privacy: .public))")
            finishStart(error: .invalidConfiguration)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self, adapter] adapterError in
            guard let self else { return }
            guard let adapterError else {
                logger.info("tunnel interface is \(adapter.interfaceName ?? "unknown", privacy: .public)")
                self.finishStart(error: nil)
                return
            }
            switch adapterError {
            case .cannotLocateTunnelFileDescriptor:
                logger.error("startTunnel failed: no utun file descriptor")
                self.finishStart(error: .couldNotDetermineFileDescriptor)
            case .dnsResolution(let failures):
                // Endpoint hostnames only; never addresses inside the network.
                let hosts = failures.map(\.address).joined(separator: ", ")
                logger.error("startTunnel failed: endpoint DNS resolution failed for \(hosts, privacy: .public)")
                self.finishStart(error: .dnsResolutionFailure)
            case .setNetworkSettings(let error):
                logger.error("startTunnel failed: setTunnelNetworkSettings: \(error.localizedDescription, privacy: .public)")
                self.finishStart(error: .couldNotSetNetworkSettings)
            case .startWireGuardBackend(let code):
                logger.error("startTunnel failed: wgTurnOn returned \(code, privacy: .public)")
                self.finishStart(error: .couldNotStartBackend)
            case .invalidState:
                // A duplicate request is coalesced by startGate before it gets here.
                // Preserve this as a real adapter failure if the adapter reports it
                // for the generation that owns the start.
                logger.error("startTunnel failed: adapter rejected generation as invalid state")
                self.finishStart(error: .invalidState)
            }
        }
    }

    /// Completes every callback parked behind the current start generation.
    private func finishStart(error: CloudTunnelProviderError?) {
        Task { [weak self] in
            guard let self else { return }
            guard let result = await startGate.finish(error: error) else {
                logger.error("startTunnel completion arrived for an inactive generation")
                return
            }
            logger.info("startTunnel finished generation \(result.generation, privacy: .public), success \(result.succeeded, privacy: .public), callbacks \(result.callbackCount, privacy: .public)")
            result.completions.forEach { $0(error) }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopTunnel (reason \(reason.rawValue, privacy: .public))")
        adapter.stop { error in
            if let error {
                logger.error("stopTunnel: adapter did not stop cleanly: \(error.localizedDescription, privacy: .public)")
            }
            completionHandler()
            // Same exit WireGuard's own macOS provider performs after a stop:
            // the provider process otherwise lingers with a torn-down adapter
            // (Apple FB 32073323), and the next start reuses it. A fresh
            // process per tunnel lifetime is the reliable shape.
            exit(0)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        guard messageData == CloudTunnelProviderMessage.runtimeConfiguration else {
            completionHandler(nil)
            return
        }
        adapter.getRuntimeConfiguration { settings in
            // Peers, handshakes, transfer counters — never the keys.
            let redacted = settings.map(self.runtimeConfigurationRedactor.redacted)
            completionHandler(redacted?.data(using: .utf8))
        }
    }

    /// The enum case name of an error without its payload. Reflection only
    /// sees the label, never the associated value, so this is safe to log.
    private static func caseName(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        if let label = mirror.children.first?.label {
            return label
        }
        return String(describing: error)
    }
}
