import Foundation

/// Mirror types decoded from the Tasks owner's JSON (cmux-tasks-core, snake
/// case). The owner is the single writer; these are read-only projections.
public nonisolated enum TaskCategory: String, Codable, Sendable, CaseIterable, Comparable {
    case triage, backlog, unstarted, started, completed, canceled

    public var rank: Int {
        switch self {
        case .triage: 0
        case .backlog: 1
        case .unstarted: 2
        case .started: 3
        case .completed, .canceled: 4
        }
    }

    public var isOpen: Bool { rank < 4 }

    public static func < (lhs: TaskCategory, rhs: TaskCategory) -> Bool {
        (lhs.rank, lhs.order) < (rhs.rank, rhs.order)
    }

    private var order: Int { self == .canceled ? 1 : 0 }
}

public nonisolated enum TaskPriority: String, Codable, Sendable, CaseIterable {
    case none, urgent, high, medium, low

    /// Sort rank: urgent first, none last.
    public var rank: Int {
        switch self {
        case .urgent: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .none: 4
        }
    }
}

public nonisolated enum TaskAttention: String, Codable, Sendable {
    case needsInput = "needs_input"
    case failed
    case review
}
