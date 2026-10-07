/// The Tasks pane layouts (decision T2): one user setting, `tasks.layout`
/// in cmux.json and Settings, default `inbox`. The raw values are the
/// setting's values.
public nonisolated enum TasksLayout: String, Sendable, CaseIterable {
    /// Dense rows grouped by status.
    case list
    /// A column per status; drag cards between columns.
    case board
    /// Attention first (agent waiting, review, failed, mine), detail on the right.
    case inbox

    /// The layout when the setting is unset.
    public static let fallback: TasksLayout = .inbox
}
