/// A mobile checklist item's progress state.
public enum MobileTodoItemState: String, Codable, CaseIterable, Sendable {
    /// Work has not started.
    case pending
    /// Work is actively progressing.
    case inProgress = "in_progress"
    /// Work is complete.
    case completed

    /// The next state in the mobile tap cycle.
    public var next: MobileTodoItemState {
        switch self {
        case .pending: .inProgress
        case .inProgress: .completed
        case .completed: .pending
        }
    }
}
