import CmuxLinkWebRTC
import CmuxMobileWire

/// The Mac acceptors' ICE servers (b2-webrtc.md 5): `read
/// signal.turn_credentials {host}` on this Mac's own host socket. Without a
/// socket, without TURN secrets on the Worker (`signal.turn_unavailable`) or
/// with an answer that does not decode, ICE is STUN only: P2P still works,
/// relayed paths do not. The acceptors cache the answer until shortly before
/// it expires.
struct HostSocketICEServers: ICEServerProvider {
    let reads: @Sendable (_ op: String, _ params: JSONValue) async throws -> ReadResultFrame
    private let decoder = TurnCredentialsDecoder()

    init(reads: @escaping @Sendable (_ op: String, _ params: JSONValue) async throws -> ReadResultFrame) {
        self.reads = reads
    }

    func iceConfiguration(for hostID: String) async throws -> ICEConfiguration {
        do {
            let result = try await reads("signal.turn_credentials", .object(["host": .string(hostID)]))
            return decoder.decode(result.value) ?? .stunOnly
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .stunOnly
        }
    }
}
