public import CmuxLink

/// Failures of a live WebRTC transport.
public enum WebRTCTransportError: Error, Sendable, Hashable {
    case closed
    case frameTooLarge(Int)
    case mediaKindUnsupported(MediaTrackKind)
}
