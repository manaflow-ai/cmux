// TasksLayoutPreference, the path and the default are generated from schemas/settings/source/tasks.json
// (SettingsSchema+Tasks*.generated.swift, cx-d5b5d).

/// `tasks.layout` in cmux.json: "list", "board" or "inbox" (default).
public struct TasksLayoutSetting {
    public nonisolated init() {}
    public nonisolated let configPath = TasksLayoutSetting.layoutPath
    public nonisolated let fallback = TasksLayoutSetting.layoutDefault
}
