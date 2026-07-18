/// Result of a nonblocking renderer frame send.
public enum TerminalRenderFrameDelivery: Equatable, Sendable {
    /// The Mach message entered the host's bounded receive queue.
    case sent

    /// The queue was full, so the obsolete intermediate frame was dropped.
    case droppedQueueFull
}
