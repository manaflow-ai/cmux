import Foundation

/// The outcome of enqueuing text into a ``MobileTerminalInputSendBuffer``.
public enum MobileTerminalInputEnqueueResult: Equatable, Sendable {
    /// The buffer was idle; the caller should begin draining it now.
    case startDraining
    /// The text was appended while the buffer is already draining.
    case queued
    /// The text was rejected because the buffer is full.
    case rejected
}
