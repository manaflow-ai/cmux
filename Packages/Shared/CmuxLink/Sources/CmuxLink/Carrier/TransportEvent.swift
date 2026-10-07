/// What a transport reports to the session. `closed` is the last event and
/// is emitted exactly once.
public enum TransportEvent: Sendable {
    case frame(TransportFrame)
    /// The transport moved to another path without dropping (ICE restart to
    /// TURN, overlay path switch).
    case pathChanged(LinkPath)
    /// A smoothed RTT sample.
    case rtt(Duration)
    case health(LinkHealth)
    /// The peer published a media track.
    case mediaTrack(MediaTrackHandle)
    case closed(TransportCloseReason)
}
