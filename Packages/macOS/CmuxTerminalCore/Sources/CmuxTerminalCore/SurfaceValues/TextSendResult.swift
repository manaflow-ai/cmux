/// The outcome of sending literal paste text to a terminal surface.
public enum TextSendResult: Equatable, Sendable {
    /// Delivered to the live runtime surface.
    case sent
    /// Accepted for ordered delivery after surface startup or a clipboard read.
    case queued
    /// The pending-input queue is at capacity.
    case inputQueueFull
    /// No runtime surface exists and none is starting.
    case surfaceUnavailable
    /// The surface's child process already exited.
    case processExited

    /// Whether the text was delivered or accepted for ordered delivery.
    public var accepted: Bool {
        switch self {
        case .sent, .queued:
            true
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            false
        }
    }
}
