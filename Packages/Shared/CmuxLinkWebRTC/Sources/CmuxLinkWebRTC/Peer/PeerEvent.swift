import CmuxLinkSignaling
@preconcurrency import WebRTC

/// What a peer connection reports to its driver, in callback order.
enum PeerEvent: Sendable {
    case candidate(ICECandidateInit)
    case gatheringComplete
    case iceState(RTCIceConnectionState)
    case selectedPair(local: String, remote: String)
    case negotiationNeeded
    case controlOpen
    case controlClosed
    case control(CarrierControlMessage)
    /// Every reliable lane delivered what the peer's `fin` announced.
    case finSatisfied
    case remoteTrack(RemoteTrackBox)
}

/// A remote media track crossing to the driver (libwebrtc objects are
/// thread-safe proxies but not `Sendable`).
struct RemoteTrackBox: @unchecked Sendable {
    let track: RTCMediaStreamTrack
}
