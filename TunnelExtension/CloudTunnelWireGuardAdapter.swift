import Foundation
import NetworkExtension
import WireGuardKit
import CmuxCloudTunnelCore
import os

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app.tunnel", category: "WireGuardAdapter")

/// WireGuardKit confines its mutable state to its own work queue. This wrapper
/// is immutable after initialization; the lifecycle calls start/stop in order.
final class CloudTunnelWireGuardAdapter: CloudTunnelAdapter, @unchecked Sendable {
    private let adapter: WireGuardAdapter

    init(provider: NEPacketTunnelProvider) {
        adapter = WireGuardAdapter(with: provider) { level, message in
            switch level {
            case .verbose: logger.debug("\(message, privacy: .private)")
            case .error: logger.error("\(message, privacy: .private)")
            }
        }
    }

    func start(configuration: String, completion: @escaping CloudTunnelProviderStartGate.Completion) {
        let parsed: TunnelConfiguration
        do {
            parsed = try TunnelConfiguration(fromWgQuickConfig: configuration, called: "cmux Cloud")
        } catch {
            // Parse failures may contain keys. Report only a stable error case.
            completion(.invalidConfiguration)
            return
        }
        adapter.start(tunnelConfiguration: parsed) { [adapter] error in
            guard let error else {
                logger.info("tunnel interface is \(adapter.interfaceName ?? "unknown", privacy: .public)")
                completion(nil)
                return
            }
            let failure: CloudTunnelProviderError
            switch error {
            case .cannotLocateTunnelFileDescriptor: failure = .couldNotDetermineFileDescriptor
            case .dnsResolution: failure = .dnsResolutionFailure
            case .setNetworkSettings: failure = .couldNotSetNetworkSettings
            case .startWireGuardBackend: failure = .couldNotStartBackend
            case .invalidState: failure = .invalidState
            }
            logger.error("adapter start failed code=\(failure.rawValue, privacy: .public)")
            completion(failure)
        }
    }

    func stop(completion: @escaping CloudTunnelProviderStartGate.StopCompletion) {
        adapter.stop { error in
            if let error {
                logger.error("adapter stop failed: \(String(describing: error), privacy: .private)")
            }
            completion()
        }
    }

    func runtimeConfiguration(completion: @escaping (String?) -> Void) {
        adapter.getRuntimeConfiguration(completionHandler: completion)
    }
}
