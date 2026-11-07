public import Foundation

/// The completion lane reported by the Mac for a workspace.
public enum MobileWorkspaceTaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case working
    case needsAttention = "needs-attention"
    case review
    case done

    public var label: String {
        switch self {
        case .todo: "To Do"
        case .working: "Working"
        case .needsAttention: "Needs Attention"
        case .review: "Review"
        case .done: "Done"
        }
    }

    public var systemImage: String {
        switch self {
        case .todo: "circle"
        case .working: "circle.dotted"
        case .needsAttention: "exclamationmark.circle.fill"
        case .review: "eye.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}
