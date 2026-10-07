public import CmuxLinkSignaling
public import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// `SignalingChannel` and `ICEServerProvider` over B1's host socket
/// (`/v1/wire/host/<host>`): `sendSignal`, the relayed signals, and
/// `read signal.turn_credentials {host}`. The session is a client of its own
/// or a lease on the Mac's shared socket (`HostSocketPool`); it reads one
/// `signalUpdates()` stream, so one adapter per session.
public final class ControlPlaneSignaling: SignalingChannel, ICEServerProvider {
    public let client: any ControlPlaneSession
    public let incoming: AsyncStream<SignalMessage>
    private let codec: SignalFrameCodec
    private let decoder = TurnCredentialsDecoder()
    private let pump: Task<Void, Never>
    /// Resolves once the relayed signals are subscribed; `send` waits for it,
    /// so no answer to this session's offer can arrive unread.
    private let subscribed: Task<AsyncStream<SignalFrame>, Never>

    public init(client: any ControlPlaneSession, codec: SignalFrameCodec = SignalFrameCodec()) {
        self.client = client
        self.codec = codec
        // Bounded like `client.signals` (E1), which it re-delivers.
        let (stream, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .bufferingNewest(256))
        incoming = stream
        let subscribed = Task { await client.signalUpdates() }
        self.subscribed = subscribed
        pump = Task {
            for await frame in await subscribed.value {
                if let message = codec.message(from: frame) { sink.yield(message) }
            }
            sink.finish()
        }
    }

    deinit { pump.cancel() }

    public func send(_ message: SignalMessage) async throws {
        _ = await subscribed.value
        try await client.sendSignal(codec.frame(for: message))
    }

    /// Mints TURN credentials; `signal.turn_unavailable` degrades to STUN
    /// only (P2P still works, relayed paths do not).
    public func iceConfiguration(for hostID: String) async throws -> ICEConfiguration {
        do {
            let result = try await client.read("signal.turn_credentials", params: .object(["host": .string(hostID)]))
            guard let configuration = decoder.decode(result.value) else { return .stunOnly }
            return configuration
        } catch ControlPlaneError.remote(let error) where error.code == "signal.turn_unavailable" {
            return .stunOnly
        }
    }
}
