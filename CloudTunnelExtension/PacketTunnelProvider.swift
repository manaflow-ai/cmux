import CmuxNextCloudTunnel
import Foundation
import Network
import NetworkExtension
import os

private let logger = Logger(subsystem: "com.cmuxterm.app.tunnel", category: "provider")

/// The opt-in Cloud Tunnel's packet tunnel: routes the Cloud networks (never a default route)
/// into utun, and runs `cmux-wg-tun` on that utun fd. The app owns enrollment and activation;
/// the config arrives in `providerConfiguration` (see ``CloudTunnelProviderConfiguration``).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let engine = TunnelEngine()
    // The KVO token for `defaultPath` (NEProvider exposes path changes only through KVO).
    /// Follows the default network path; cancelled in stopTunnel.
    private var pathWatch: Task<Void, Never>?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = ProviderCompletion(completionHandler)
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard let saved = CloudTunnelProviderConfiguration(dictionary: providerConfiguration) else {
            completion(ProviderError.missingConfiguration)
            return
        }
        let configuration: CloudTunnelConfiguration
        do {
            configuration = try CloudTunnelConfiguration(wgQuick: saved.wgQuick)
        } catch {
            completion(ProviderError.invalidConfiguration(String(describing: error)))
            return
        }
        logger.notice("starting: \(configuration.description, privacy: .public)")
        let engine = engine
        setTunnelNetworkSettings(configuration.networkSettings()) { error in
            if let error {
                logger.error("network settings: \(error.localizedDescription, privacy: .public)")
                completion(error)
                return
            }
            // task-owner: one start; the completion ends it.
            Task {
                do {
                    try await engine.start(wgQuick: saved.wgQuick)
                    logger.notice("engine running")
                    completion(nil)
                } catch {
                    logger.error("engine: \(error.localizedDescription, privacy: .public)")
                    completion(error)
                }
            }
        }
        // NEProvider.defaultPath is not visible to Swift in the macOS 26 SDK (the nightly's compile
        // failed on it); NWPathMonitor is the supported path source. Only a real change (Wi-Fi to
        // Ethernet, wake) reaches the engine: the monitor's first value is the current path.
        pathWatch?.cancel()
        pathWatch = Task {
            var previous: NWPath?
            for await path in NWPathMonitor() {
                defer { previous = path }
                guard let previous, previous != path else { continue }
                await engine.networkChanged()
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("stopping, reason \(reason.rawValue, privacy: .public)")
        pathWatch?.cancel()
        pathWatch = nil
        let completion = ProviderCompletion { _ in completionHandler() }
        let engine = engine
        Task {
            await engine.stop()
            completion(nil)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        let engine = engine
        let send = MessageReply(completionHandler)
        Task {
            guard let stats = await engine.stats() else { return send(nil) }
            let body: [String: Int64] = [
                "txBytes": Int64(clamping: stats.tx_bytes),
                "rxBytes": Int64(clamping: stats.rx_bytes),
                "lastHandshakeUnix": stats.last_handshake_unix,
            ]
            send(try? JSONSerialization.data(withJSONObject: body))
        }
    }
}

/// Carries an app-message reply handler into a task.
private final class MessageReply: @unchecked Sendable {
    // Safe: immutable, called exactly once, from any thread (NetworkExtension allows it).
    private let reply: (Data?) -> Void

    init(_ reply: @escaping (Data?) -> Void) { self.reply = reply }

    func callAsFunction(_ data: Data?) { reply(data) }
}
