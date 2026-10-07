public import CmuxLink
import Foundation

/// One live, authenticated WebRTC peer connection (a3-link.md section 8).
/// Lanes ride data channels (b2-webrtc.md section 6); media rides tracks.
public final class WebRTCTransport: LinkTransport {
    public let events: AsyncStream<TransportEvent>
    public var capabilities: TransportCapabilities { .stream }
    /// The identity key the peer proved (bound to its DTLS fingerprint).
    public let remoteKey: WebRTCPublicKey
    public let peerIdentity: LinkPeerIdentity?
    let connection: WebRTCConnection
    private let highWater: UInt64

    init(events: AsyncStream<TransportEvent>, connection: WebRTCConnection, remoteKey: WebRTCPublicKey, install: String?) {
        self.events = events
        self.connection = connection
        self.remoteKey = remoteKey
        highWater = connection.context.configuration.highWaterBytes
        peerIdentity = LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: remoteKey.x963Representation, install: install)
    }

    public var path: LinkPath {
        get async { await connection.path }
    }

    public func send(_ frame: TransportFrame) async throws {
        guard frame.bytes.count <= TransportCapabilities.stream.maxFrameBytes else {
            throw WebRTCTransportError.frameTooLarge(frame.bytes.count)
        }
        try Task.checkCancellation()
        try await connection.pacer.pace(frame.bytes.count)
        do {
            try await connection.peer.send(frame, highWater: highWater)
        } catch {
            throw WebRTCTransportError.closed
        }
    }

    public func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        try await connection.publish(descriptor)
    }

    public func close() async {
        await connection.close()
    }

    /// Restarts ICE now (dialer; the host follows the dialer's offer).
    public func restartICE() async {
        await connection.restartICE()
    }
}
