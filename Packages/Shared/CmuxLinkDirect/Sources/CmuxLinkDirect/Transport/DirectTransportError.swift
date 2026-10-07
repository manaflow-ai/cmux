/// Errors a live direct transport throws.
public enum DirectTransportError: Error, Sendable, Hashable {
    /// The transport is closed or closing.
    case closed
    /// The frame exceeds `capabilities.maxFrameBytes`.
    case frameTooLarge(Int)
    /// The direct carrier moves frames only; media goes through channels.
    case mediaUnsupported
}
