import Foundation
import NetworkExtension
import os
import WireGuardKit

/// Runs this Mac's WireGuard tunnel to its Cloud VM private network inside the
/// app's own VPN extension.
///
/// This is the alternative to the root launchd job that runs `wg-quick`: the
/// system starts and stops this provider, so connecting costs one
/// VPN-permission dialog instead of an administrator password, and nothing is
/// installed outside the app bundle.
///
/// Nothing reaches this until the app is signed with
/// `com.apple.developer.networking.networkextension`; without it the app
/// selects the launchd backend instead.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { level, message in
            // The only diagnostic available once this is running: an extension
            // has no stdout anyone will see.
            os_log(
                "%{public}@",
                log: OSLog(subsystem: "com.cmuxterm.app.tunnel", category: "wireguard"),
                type: level == .error ? .error : .default,
                message
            )
        }
    }()

    enum ProviderError: Error, LocalizedError {
        case missingConfiguration
        case malformedConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "The tunnel was started without a configuration."
            case .malformedConfiguration(let detail):
                return "The tunnel configuration could not be read: \(detail)."
            }
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // The config travels as text in `providerConfiguration`, not as a path:
        // an extension runs in its own sandbox and cannot read the app's
        // container.
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let quickConfig = proto.providerConfiguration?["wgQuickConfig"] as? String,
            !quickConfig.isEmpty
        else {
            completionHandler(ProviderError.missingConfiguration)
            return
        }
        let configuration: TunnelConfiguration
        do {
            // wg-quick text, the same thing the launchd path applies, so the
            // two backends cannot drift into disagreeing formats.
            configuration = try TunnelConfiguration(fromWgQuickConfig: quickConfig, called: "cmux")
        } catch {
            completionHandler(ProviderError.malformedConfiguration(String(describing: error)))
            return
        }
        adapter.start(tunnelConfiguration: configuration) { adapterError in
            completionHandler(adapterError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        adapter.stop { _ in
            completionHandler()
        }
    }

    /// Re-applies a configuration the app changed while the tunnel was up -- a
    /// re-enrollment, new keys, a different account. Without this the tunnel
    /// keeps carrying the previous peer, which reads as connected while
    /// reaching nothing.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard
            let quickConfig = String(data: messageData, encoding: .utf8),
            let configuration = try? TunnelConfiguration(fromWgQuickConfig: quickConfig, called: "cmux")
        else {
            completionHandler?(nil)
            return
        }
        adapter.update(tunnelConfiguration: configuration) { error in
            completionHandler?(error == nil ? Data([1]) : nil)
        }
    }
}
