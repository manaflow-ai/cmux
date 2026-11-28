public import CmuxNextDesign

/// Debug Settings declarations of the Tasks pane (DEV and NIGHTLY). The
/// layout itself is a user setting (`tasks.layout`, ``TasksLayout``).
public nonisolated enum TasksTunables {
    public static let section = TunableSection(id: "tasks", title: "Tasks", symbol: "checklist", order: 41)

    public static let rowHeight = Tunable<Double>.number(
        "tasks.rowHeight", section, "Row height", help: "Height of a task row in the list and inbox.",
        default: 30, range: 22...48, step: 1, unit: .points, code: "TasksTunables.rowHeight")

    public static let boardColumnWidth = Tunable<Double>.number(
        "tasks.boardColumnWidth", section, "Board column width", help: "Width of one board column.",
        default: 280, range: 200...420, step: 4, unit: .points, code: "TasksTunables.boardColumnWidth")

    public static var all: [TunableDescriptor] { [rowHeight.descriptor, boardColumnWidth.descriptor] }
}
