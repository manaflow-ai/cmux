import Foundation
import NetworkExtension
import CmuxCloudTunnelCore
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app.tunnel", category: "PacketTunnelProvider")

/// Runs the saved Cloud WireGuard configuration in a macOS system extension.
/// The app owns enrollment and explicit activation. The provider owns ordered
/// start/stop callbacks; it never changes another VPN's configuration.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    // Set once in init after super.init makes the provider available to WireGuardKit.
    private var adapter: CloudTunnelWireGuardAdapter?
    private var lifecycle: CloudTunnelProviderStartGate?
    private var lifecycleTask: Task<Void, Never>?
    private let runtimeConfigurationRedactor = CloudTunnelRuntimeConfigurationRedactor()

    override init() {
        super.init()
        let adapter = CloudTunnelWireGuardAdapter(provider: self)
        self.adapter = adapter
        let lifecycle = CloudTunnelProviderStartGate(
            adapter: adapter,
            diagnostic: { message in
                logger.info("pid=\(getpid(), privacy: .public) \(message, privacy: .public)")
            },
            // Like WireGuard's macOS provider, exit after teardown (Apple FB 32073323).
            // The lifecycle drains pending callbacks before retiring this process.
            didStop: { exit(0) }
        )
        self.lifecycle = lifecycle
        lifecycleTask = Task { await lifecycle.run() }
    }

    deinit {
        // A task cancellation would discard adapter completions still in flight.
        // Keep the consumer alive until the same ordered stop path drains them.
        lifecycle?.stop {}
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let lifecycle else { completionHandler(CloudTunnelProviderError.invalidState); return }
        let completion = CloudTunnelProviderCompletion(completionHandler)
        lifecycle.start(configuration: savedConfiguration()) { error in completion.call(error) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        guard let lifecycle else { completionHandler(); return }
        logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        let completion = CloudTunnelProviderCompletion { _ in completionHandler() }
        lifecycle.stop { completion.call(nil) }
    }

    private func savedConfiguration() -> Result<String, CloudTunnelProviderError> {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let config = providerProtocol.providerConfiguration,
              let text = config[CloudTunnelProviderConfigurationKeys.wgQuickConfig] as? String,
              !text.isEmpty else { return .failure(.missingConfiguration) }
        guard config[CloudTunnelProviderConfigurationKeys.schemaVersion] as? Int
                == CloudTunnelProviderConfigurationKeys.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        return .success(text)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        guard messageData == CloudTunnelProviderMessage.runtimeConfiguration, let adapter else {
            completionHandler(nil)
            return
        }
        // This is a diagnostic snapshot of the adapter, not a readiness signal.
        // WireGuardKit serializes reads with its own mutations; retaining its
        // transition-time snapshot helps diagnose a slow start or stop.
        adapter.runtimeConfiguration { [runtimeConfigurationRedactor] settings in
            let redacted = settings.map(runtimeConfigurationRedactor.redacted)
            completionHandler(redacted?.data(using: .utf8))
        }
    }
}
