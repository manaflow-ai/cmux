// TasksLayoutPreference, the path and the default are generated from schemas/settings/source/tasks.json
// (SettingsSchema+Tasks*.generated.swift, cx-d5b5d).

/// `tasks.layout` in cmux.json: "list", "board" or "inbox" (default).
public struct TasksLayoutSetting {
    public nonisolated init() {}
    public nonisolated let configPath = TasksLayoutSetting.layoutPath
    public nonisolated let fallback = TasksLayoutSetting.layoutDefault

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
