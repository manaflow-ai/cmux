import CmuxLink

/// What a peer connection's channels carry.
enum PeerMode: Sendable, Hashable {
    /// V1: the `cmux/1 ctl` channel plus one data channel per lane.
    case lanes
    /// V2 underlay: one `wg` channel (`ordered: false, maxRetransmits: 0`)
    /// of opaque datagrams (b3-webrtc-wg.md section 1).
    case datagram

    var primaryLabel: String {
        switch self {
        case .lanes: LaneLabel.control
        case .datagram: LaneLabel.datagram
        }
    }

    var carrier: CarrierKind {
        switch self {
        case .lanes: .webrtc
        case .datagram: .webrtcWireGuard
        }
    }

    /// The lane datagrams are reported on inside the event stream.
    static let datagramLane = TransportLane(reliability: .unreliableUnordered, priority: .media)
}
