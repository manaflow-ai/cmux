/// The Tasks pane layout (plans/cmux-next/tasks.md decision T2). The Tasks
/// module declares the same raw values (`TasksLayout`); the App maps them.
public nonisolated enum TasksLayoutPreference: String, Sendable, Hashable, CaseIterable {
    /// Dense rows grouped by status.
    case list
    /// A column per status.
    case board
    /// Attention first, with the selected task's detail beside it.
    case inbox
}

/// `tasks.layout` in cmux.json: "list", "board" or "inbox" (default).
public struct TasksLayoutSetting {
    public nonisolated init() {}
    public nonisolated let configPath = ["tasks", "layout"]
    public nonisolated let fallback: TasksLayoutPreference = .inbox

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    nonisolated func parse(_ root: JSONValue) -> (TasksLayoutPreference, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let layout = TasksLayoutPreference(rawValue: text) else {
            let choices = TasksLayoutPreference.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tasks.layout", message: "expected one of \(choices)"))
        }
        return (layout, nil)
    }
}
