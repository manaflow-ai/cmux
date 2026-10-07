public import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// `SignalingChannel` and `ICEServerProvider` over B1's `ControlPlaneClient`
/// on the host socket (`/v1/wire/host/<host>`): `sendSignal`, `signals`, and
/// `read signal.turn_credentials {host}`. It consumes `client.signals`, so
/// one adapter per client.
public final class ControlPlaneSignaling: SignalingChannel, ICEServerProvider {
    public let client: ControlPlaneClient
    public let incoming: AsyncStream<SignalMessage>
    private let codec: SignalFrameCodec
    private let decoder = TurnCredentialsDecoder()
    private let pump: Task<Void, Never>

    public init(client: ControlPlaneClient, codec: SignalFrameCodec = SignalFrameCodec()) {
        self.client = client
        self.codec = codec
        let (stream, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .unbounded)
        incoming = stream
        let frames = client.signals
        pump = Task {
            for await frame in frames {
                if let message = codec.message(from: frame) { sink.yield(message) }
            }
            sink.finish()
        }
    }

    deinit { pump.cancel() }

    public func send(_ message: SignalMessage) async throws {
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
