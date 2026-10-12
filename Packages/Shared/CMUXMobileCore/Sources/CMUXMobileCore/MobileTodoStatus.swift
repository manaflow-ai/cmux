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
        guard statuses.contains(self) else { return .todo }
        // The status after this one, wrapping from the last to the first.
        return statuses.drop { $0 != self }.dropFirst().first ?? statuses.first ?? .todo
    }
}
