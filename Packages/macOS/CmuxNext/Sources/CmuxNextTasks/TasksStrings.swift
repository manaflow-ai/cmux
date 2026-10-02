import Foundation

/// Strings of the Tasks pane (Resources/Localizable.xcstrings). Few labels
/// by design: glyphs carry status, priority and people.
nonisolated enum TasksStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("pane.title", "Tasks") }
    static var empty: String { t("pane.empty", "No tasks") }
    static var inboxZero: String { t("inbox.zero", "Nothing needs you") }
    static var needsInput: String { t("inbox.needsInput", "Waiting for you") }
    static var review: String { t("inbox.review", "Ready for review") }
    static var failed: String { t("inbox.failed", "Agent failed") }
    static var mine: String { t("inbox.mine", "Assigned to you") }
    static var rest: String { t("inbox.rest", "Everything else") }
    static var plan: String { t("detail.plan", "Plan") }
    static var unassigned: String { t("detail.unassigned", "Unassigned") }
    static var disconnected: String { t("owner.disconnected", "Tasks is unreachable") }
    static var ownerNotRunning: String { t("owner.notRunning", "Tasks is not running. Start it with cmux task serve.") }
    static var ownerUnreachable: String { t("owner.lost", "Lost the connection to Tasks") }

    static func session(_ status: TaskSessionStatus) -> String {
        switch status {
        case .pending, .claimed: t("session.starting", "Starting")
        case .working: t("session.working", "Working")
        case .awaitingInput: t("session.waiting", "Waiting for you")
        case .done: t("session.done", "Done")
        case .failed: t("session.failed", "Failed")
        case .canceled: t("session.canceled", "Canceled")
        }
    }

    /// Palette titles for catalog ops (Resources/tasks-catalog.json).
    static func palette(op: String, fallback: String) -> String {
        switch op {
        case "task.create": t("palette.task.create", "New Task")
        case "task.update": t("palette.task.update", "Change Task Status")
        case "task.archive": t("palette.task.archive", "Archive Task")
        case "task.delete": t("palette.task.delete", "Delete Task")
        case "task.delegate": t("palette.task.delegate", "Delegate Task to Agent")
        case "task.comment.add": t("palette.task.comment.add", "Comment on Task")
        default: fallback
        }
    }

    static var openTasks: String { t("palette.openTasks", "Open Tasks") }
}
