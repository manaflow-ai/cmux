/// Errors the seam throws to features.
public enum LinkError: Error, Sendable, Hashable {
    /// The session is closed.
    case closed(LinkCloseReason)
    case channelClosed
    /// The session has reached a configured resource limit.
    case capacityExceeded(resource: String, limit: Int)
    /// The payload exceeds the path's or the configuration's frame limit.
    case messageTooLarge(size: Int, limit: Int)
    /// The current path cannot carry this class (bulk or media on the
    /// control-sized relay).
    case unsupportedOnPath(PathKind)
    /// There is no live transport for an operation that needs one.
    case notConnected
    /// Every carrier failed.
    case allCarriersFailed([String])
}
