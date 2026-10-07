public import CmuxLink
public import Foundation

/// What an underlay reports. `closed` is the last event, emitted once.
public enum UnderlayEvent: Sendable {
    /// One received data channel message (one WireGuard datagram).
    case datagram(Data)
    /// ICE moved to another candidate pair (for example an ICE restart that
    /// fell back to TURN) without dropping the channel.
    case pathChanged(PathKind)
    case closed(UnderlayCloseReason)
}
