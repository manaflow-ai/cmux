/// The outcome of atomically pasting one complete prompt and pressing its
/// submit key.
public enum PromptSubmissionSendResult: Equatable, Sendable {
    /// Delivered to the live runtime surface as one transaction.
    case sent
    /// Queued as one transaction for an imminently-started surface.
    case queued
    /// Physical terminal input may still be present in the agent composer.
    case composerBusy
    /// The requested submit key is not supported.
    case unknownKey
    /// The pending-input queue is at capacity.
    case inputQueueFull
    /// Hook attribution is at capacity, so safe delivery was not attempted.
    case submissionUnavailable
    /// No runtime surface exists and none can be started.
    case surfaceUnavailable
    /// The surface's child process already exited.
    case processExited

    /// Whether the complete prompt transaction was accepted.
    public var accepted: Bool {
        switch self {
        case .sent, .queued:
            true
        case .composerBusy, .unknownKey, .inputQueueFull,
             .submissionUnavailable, .surfaceUnavailable, .processExited:
            false
        }
    }
}
