/// What a conversation's agent is doing.
public enum ConversationStatus: Hashable, Sendable {
    /// No agent process; the next message starts one.
    case idle
    /// Ready for a message.
    case ready
    /// Working on a turn.
    case running
    /// Waiting for the user's answer to an approval request.
    case waiting
    /// The agent process stopped unexpectedly.
    case disconnected
    /// Stopped by the user; history is kept.
    case closed
    /// Deleted on the backend (here or by another client).
    case deleted
    /// A status this client does not know; the raw value is kept.
    case other(String)

    /// Maps a backend status name (`idle`, `ready`, `running`, …).
    /// - Parameter raw: The backend's status name.
    public init(raw: String) {
        switch raw {
        case "idle": self = .idle
        case "ready": self = .ready
        case "running": self = .running
        case "waiting": self = .waiting
        case "disconnected": self = .disconnected
        case "closed": self = .closed
        case "deleted", "purged": self = .deleted
        default: self = .other(raw)
        }
    }

    /// Whether a turn is in progress.
    public var isBusy: Bool { self == .running || self == .waiting }
}
