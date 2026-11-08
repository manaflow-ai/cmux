/// A workspace's effective todo status on the mobile wire.
public enum MobileTodoStatus: String, Codable, CaseIterable, Sendable {
    /// Work has not started.
    case todo
    /// Work is actively progressing.
    case working
    /// Work is waiting for attention or input.
    case needsAttention = "needs-attention"
    /// Work is ready for review.
    case review
    /// Work is complete.
    case done

    /// The next status in the same cycle used by the Mac todo controls.
    public var next: MobileTodoStatus {
        let statuses = Self.allCases
        guard let index = statuses.firstIndex(of: self) else { return .todo }
        return statuses[(index + 1) % statuses.count]
    }
}
