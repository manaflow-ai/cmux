@preconcurrency import WebRTC

/// What the peer knows about one data channel.
struct PeerChannelEntry {
    let channel: RTCDataChannel
    /// nil for the control channel.
    let label: LaneLabel?
}
