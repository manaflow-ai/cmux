import CmuxMobileWire

/// Why the phone's session or a channel open failed.
public enum MobileLinkClientError: Error, Hashable, Sendable {
    /// The host answered the hello with `error` (for example `auth.forbidden`).
    case helloRejected(code: String, message: String)
    /// The host refused the channel (`channel.refused`).
    case refused(code: String, message: String, retryable: Bool)
    /// The link session closed or lost the channel before an answer.
    case linkLost
    /// The host answered something the binding does not allow here.
    case protocolViolation(String)
    /// `close()` was called.
    case closed
}
