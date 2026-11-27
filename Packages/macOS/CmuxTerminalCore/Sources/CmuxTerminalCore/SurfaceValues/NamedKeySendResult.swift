/// The outcome of sending a named key (arrow, escape, enter) to a surface.
public enum NamedKeySendResult: Equatable, Sendable {
    /// Delivered to the live runtime surface.
    case sent
    /// Queued for ordered delivery after surface startup or a clipboard read.
    case queued
    /// The key name is not recognized.
    case unknownKey
    /// The pending-input queue is at capacity.
    case inputQueueFull
    /// No runtime surface exists and none is starting.
    case surfaceUnavailable
    /// The surface's child process already exited.
    case processExited

    /// Whether the named key was delivered or accepted for ordered delivery.
    /// `false` means it never reached the PTY or an input queue.
    public var accepted: Bool {
        switch self {
        case .sent, .queued:
            return true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }
}
