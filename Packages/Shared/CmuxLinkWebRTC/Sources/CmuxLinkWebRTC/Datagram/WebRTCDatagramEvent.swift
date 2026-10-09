public import CmuxLink
public import Foundation

/// What a datagram channel reports. `closed` is last and emitted once.
public enum WebRTCDatagramEvent: Sendable {
    case datagram(Data)
    /// ICE moved to another candidate pair without dropping the channel.
    case pathChanged(PathKind)
    case closed(WebRTCDatagramCloseReason)
}
