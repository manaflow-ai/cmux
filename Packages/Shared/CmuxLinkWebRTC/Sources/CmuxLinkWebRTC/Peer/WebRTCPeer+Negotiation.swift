import CmuxLink
import Foundation
@preconcurrency import WebRTC

/// Async wrappers over the peer connection's completion-handler API.
extension WebRTCPeer {
    private func requireConnection() throws -> RTCPeerConnection {
        guard let connection, !isClosed else { throw WebRTCPeerError.closed }
        return connection
    }

    var signalingState: RTCSignalingState { connection?.signalingState ?? .closed }

    var localSDP: String? { connection?.localDescription?.sdp }

    /// Creates an offer and sets it as the local description; returns the
    /// SDP actually applied.
    func makeOffer() async throws -> String {
        let connection = try requireConnection()
        let constraints = factory.constraints()
        let offer = try await describe { connection.offer(for: constraints, completionHandler: $0) }
        try await apply { connection.setLocalDescription(offer.value, completionHandler: $0) }
        return connection.localDescription?.sdp ?? offer.value.sdp
    }

    func makeAnswer() async throws -> String {
        let connection = try requireConnection()
        let constraints = factory.constraints()
        let answer = try await describe { connection.answer(for: constraints, completionHandler: $0) }
        try await apply { connection.setLocalDescription(answer.value, completionHandler: $0) }
        return connection.localDescription?.sdp ?? answer.value.sdp
    }

    func setRemote(_ sdp: String, type: RTCSdpType) async throws {
        let connection = try requireConnection()
        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await apply { connection.setRemoteDescription(description, completionHandler: $0) }
    }

    func addCandidate(_ candidate: ICECandidateInit) async throws {
        let connection = try requireConnection()
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0), sdpMid: candidate.sdpMid)
        try await apply { connection.add(ice, completionHandler: $0) }
    }

    /// New ICE servers (fresh TURN credentials) before an ICE restart.
    func updateICEServers(_ ice: ICEConfiguration) {
        guard let connection, !isClosed else { return }
        let configuration = connection.configuration
        configuration.iceServers = WebRTCFactory.servers(ice)
        _ = connection.setConfiguration(configuration)
    }

    func restartICE() {
        connection?.restartIce()
    }

    /// The selected candidate pair and its RTT, read once from `getStats`.
    func selectedPairStats() async -> (local: CandidateType, remote: CandidateType, rtt: Duration?)? {
        guard let connection, !isClosed else { return nil }
        let report: StatsBox = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: StatsBox(report: $0)) }
        }
        return report.selectedPair()
    }

    private struct Described: @unchecked Sendable {
        let value: RTCSessionDescription
    }

    private func describe(
        _ call: (@escaping @Sendable (RTCSessionDescription?, (any Error)?) -> Void) -> Void
    ) async throws -> Described {
        try await withCheckedThrowingContinuation { continuation in
            call { description, error in
                if let description {
                    continuation.resume(returning: Described(value: description))
                } else {
                    continuation.resume(throwing: error ?? WebRTCPeerError.closed)
                }
            }
        }
    }

    private func apply(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            call { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
