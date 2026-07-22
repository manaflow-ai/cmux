import CMUXMobileCore
import CmuxMobileSupport

extension MobileTodoStatus {
    var systemImage: String {
        switch self {
        case .todo: "circle"
        case .working: "circle.dotted"
        case .needsAttention: "exclamationmark.circle.fill"
        case .review: "eye.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .todo:
            L10n.string("mobile.todo.status.todo", defaultValue: "Todo")
        case .working:
            L10n.string("mobile.todo.status.working", defaultValue: "Working")
        case .needsAttention:
            L10n.string("mobile.todo.status.needsAttention", defaultValue: "Needs Attention")
        case .review:
            L10n.string("mobile.todo.status.review", defaultValue: "Review")
        case .done:
            L10n.string("mobile.todo.status.done", defaultValue: "Done")
        }
    }
}
