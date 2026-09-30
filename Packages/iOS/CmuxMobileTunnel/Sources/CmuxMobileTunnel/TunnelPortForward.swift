import Foundation
import NIOCore
import NIOTransportServices

/// A listener on the phone's loopback that carries each accepted connection
/// to `targetHost:targetPort` at a backend's exit (`ssh -L` shape).
///
/// The native browser needs these for loopback pages: iOS never sends
/// `localhost`/`127.0.0.1` to a proxy, so the exit's loopback ports are
/// mirrored onto the phone's own.
public final class TunnelPortForward: Sendable {
    public let targetHost: String
    public let targetPort: Int
    /// The bound loopback port.
    public let localPort: Int
    private let listener: any Channel
    private let relays: TunnelTaskSet

    private init(targetHost: String, targetPort: Int, localPort: Int, listener: any Channel, relays: TunnelTaskSet) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.localPort = localPort
        self.listener = listener
        self.relays = relays
    }

    /// Starts forwarding. `localPort` 0 picks a free port. Fails when the
    /// port is taken by any socket (IPv4, IPv6, or wildcard).
    public static func start(
        backend: any SocksConnectBackend,
        targetHost: String,
        targetPort: Int,
        localPort: Int = 0,
        maximumConnections: Int = 128
    ) async throws -> TunnelPortForward {
        let relays = TunnelTaskSet(limit: maximumConnections)
        let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer { inbound in
                inbound.eventLoop.makeCompletedFuture {
                    let stream = try NIOChannelByteStream.installSync(on: inbound)
                    Task {
                        let started = await relays.start {
                            do {
                                let exit = try await backend.open(host: targetHost, port: targetPort)
                                await TunnelRelay(stream, exit).run()
                            } catch {
                                await stream.close()
                            }
                        }
                        if !started { await stream.close() }
                    }
                }
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: "127.0.0.1", port: localPort)
            .get()
        guard let port = listener.localAddress?.port else {
            try? await listener.close()
            throw TunnelOpenError.generalFailure
        }
        return TunnelPortForward(
            targetHost: targetHost, targetPort: targetPort, localPort: port, listener: listener, relays: relays
        )
    }

    public var isListening: Bool { listener.isActive }

    /// Stops accepting and aborts every open connection.
    public func stop() async {
        try? await listener.close()
        await relays.cancelAll()
    }
}
