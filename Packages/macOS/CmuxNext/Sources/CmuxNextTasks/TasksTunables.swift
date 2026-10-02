public import CmuxNextDesign

/// Pane layout prototypes (`tasks.layout` in Debug Settings, DEV and NIGHTLY
/// only). Release builds use the layout Lawrence picks after dogfood.
public nonisolated enum TasksLayout: String, Sendable, CaseIterable, TunableChoice {
    /// Dense rows grouped by status.
    case list
    /// A column per status; drag cards between columns.
    case board
    /// Attention first (agent waiting, review, failed, mine), detail on the right.
    case inbox

    public var tunableTitle: String {
        switch self {
        case .list: "List (grouped by status)"
        case .board: "Board (column per status)"
        case .inbox: "Inbox (attention first + detail)"
        }
    }
}

/// Debug Settings declarations of the Tasks pane.
public nonisolated enum TasksTunables {
    public static let section = TunableSection(id: "tasks", title: "Tasks", symbol: "checklist", order: 41)

    public static let layout = Tunable<TasksLayout>.choice(
        "tasks.layout", section, "Layout", help: "Prototype layout of the Tasks pane. Switches live.",
        default: .inbox, code: "TasksTunables.layout")

    public static let rowHeight = Tunable<Double>.number(
        "tasks.rowHeight", section, "Row height", help: "Height of a task row in the list and inbox.",
        default: 30, range: 22...48, step: 1, unit: .points, code: "TasksTunables.rowHeight")

    public static let boardColumnWidth = Tunable<Double>.number(
        "tasks.boardColumnWidth", section, "Board column width", help: "Width of one board column.",
        default: 280, range: 200...420, step: 4, unit: .points, code: "TasksTunables.boardColumnWidth")

    public static var all: [TunableDescriptor] { [layout.descriptor, rowHeight.descriptor, boardColumnWidth.descriptor] }
}
