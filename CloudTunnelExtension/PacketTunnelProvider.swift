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
    // The network path watch (NWPathMonitor on its own queue). NEProvider's `defaultPath` is not
    // available in the macOS 26.5 SDK; Network.framework's monitor is the documented replacement.
    private var pathWatch: PathWatch?

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
        pathWatch?.cancel()
        pathWatch = PathWatch(engine: engine)
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

/// The provider's network path watch: an `NWPathMonitor` on its own serial queue (never the main
/// thread), through the path rule ``CloudTunnelPathChangeGate``: the monitor's first path is the
/// current one, so only a real change after it (Wi-Fi to Ethernet, wake) rebinds the engine.
private final class PathWatch: @unchecked Sendable {
    // Safe: `gate` is read and written only in the monitor's handler, which runs on `queue`, a
    // serial queue; `monitor` and `queue` never change and are thread-safe.
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cmuxterm.app.tunnel.path", qos: .utility)
    private var gate = CloudTunnelPathChangeGate<Network.NWPath>()

    init(engine: TunnelEngine) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.admit(path) else { return }
            // task-owner: one rebind per real change; the engine actor orders it with start and stop.
            Task { await engine.networkChanged() }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    func cancel() { monitor.cancel() }

    /// On `queue` only (the monitor's handler).
    private func admit(_ path: Network.NWPath) -> Bool { gate.admit(path) }
}

/// Carries an app-message reply handler into a task.
private final class MessageReply: @unchecked Sendable {
    // Safe: immutable, called exactly once, from any thread (NetworkExtension allows it).
    private let reply: (Data?) -> Void

    init(_ reply: @escaping (Data?) -> Void) { self.reply = reply }

    func callAsFunction(_ data: Data?) { reply(data) }
}
