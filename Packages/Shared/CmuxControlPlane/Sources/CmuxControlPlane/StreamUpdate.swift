public import CmuxMobileWire

/// What a stream subscriber applies to its mirror, in order. Events are delivered
/// only when contiguous (`seq == mirror.seq + 1`); a gap is repaired by the client
/// with `snapshot.request` and arrives as a new snapshot.
public enum StreamUpdate: Hashable, Sendable {
    case snapshot(SnapshotFrame)
    case event(EventFrame)
}
