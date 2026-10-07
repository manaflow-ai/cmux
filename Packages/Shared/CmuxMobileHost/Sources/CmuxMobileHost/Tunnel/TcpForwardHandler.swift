import CmuxLink
public import CmuxMobileLink
public import CmuxMobileWire
import Foundation

/// Serves `tcp.forward` (c14-web.md section 3): checks the gate and the port
/// policy against the Mac's directory at open time, caps streams, connects
/// to this Mac's loopback and pumps bytes both ways until both directions
/// ended (then `channel.closed`) or one side fails.
public struct TcpForwardHandler: MobileChannelHandler {
    static let window: UInt32 = 1 << 20

    let configuration: MobileTunnelConfiguration
    let ports: any MobileTunnelPortDirectory
    let connector: any MobileLoopbackConnector
    let limiter: TunnelStreamLimiter

    init(configuration: MobileTunnelConfiguration, ports: any MobileTunnelPortDirectory,
         connector: any MobileLoopbackConnector, limiter: TunnelStreamLimiter) {
        self.configuration = configuration
        self.ports = ports
        self.connector = connector
        self.limiter = limiter
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        // Only `port`: a phone can never name a host or any other target.
        guard Set(open.params.keys) == ["port"],
              let params = try? JSONValue.object(open.params).decode(as: TcpForwardParams.self) else {
            await channel.refuse(code: "validation.invalid", message: "bad tcp.forward params")
            return
        }
        let policy = MobileTunnelPolicy(configuration: configuration)
        let entry: TunnelPort
        switch policy.check(params.port, advertised: await ports.ports(for: principal)) {
        case .failure(let refusal):
            await channel.refuse(code: refusal.code, message: "port \(params.port) is not forwardable",
                                 details: .object(["reason": .string(refusal.reason)]))
            return
        case .success(let found):
            entry = found
        }
        guard await limiter.acquire(principal.install) else {
            await channel.refuse(code: "tunnel.limit", message: "too many forwarded connections", retryable: true)
            return
        }
        await serveAcquired(channel, entry: entry, gate: gate)
        await limiter.release(principal.install)
    }

    private func serveAcquired(_ channel: MobileChannel, entry: TunnelPort, gate: MobileSessionGate) async {
        let socket: any MobileLoopbackSocket
        do {
            socket = try await connector.connect(port: entry.port, timeout: configuration.connectTimeout)
        } catch {
            await channel.refuse(code: "tunnel.connect_refused", message: "nothing accepts on port \(entry.port)",
                                 retryable: true)
            return
        }
        let opened = TcpForwardOpenedParams(port: entry.port, source: entry.source)
        guard let params = try? JSONValue(encoding: opened).objectValue,
              (try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(channel: channel.id, window: Self.window,
                                                                                params: params, resumed: false)))) != nil
        else {
            await socket.close()
            await channel.abort()
            return
        }
        await TcpForwardPump(channel: channel, socket: socket, gate: gate, chunkBytes: configuration.chunkBytes).run()
    }
}
