/// Data-path failures of a peer connection.
enum WebRTCPeerError: Error, Sendable, Hashable {
    case closed
    case channelUnavailable
    case sendFailed
}
