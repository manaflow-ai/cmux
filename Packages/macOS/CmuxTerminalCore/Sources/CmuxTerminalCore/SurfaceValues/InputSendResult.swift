/// The outcome of sending text input to a surface.
public enum InputSendResult: Equatable, Sendable {
    /// Delivered to the live runtime surface.
    case sent
    /// Queued for an imminently-started surface.
    case queued
    /// The pending-input queue is at capacity.
    case inputQueueFull
    /// No runtime surface exists and none is starting.
    case surfaceUnavailable
    /// The surface's child process already exited.
    case processExited

    /// Whether the input was delivered to the surface or queued for an
    /// imminently-started surface. `false` means it never reached the PTY.
    public var accepted: Bool {
        switch self {
        case .sent, .queued:
            return true
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }
}
