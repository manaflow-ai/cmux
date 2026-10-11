/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum TaskSettingsSchema {
    /// The Tasks pane (plans/cmux-next/tasks.md section 9).
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.tasks", "Tasks")
        return [
            SettingDescriptor(
                TasksLayoutSetting().configPath, section: .general, group: group,
                title: SettingsText.keyed("settings.tasks.layout", "Tasks Layout"),
                help: SettingsText.keyed("settings.tasks.layout.help",
                                        "Inbox lists what needs you first, with the task beside it. Changes apply at once."),
                kind: .choice([
                    SettingChoice(TasksLayoutPreference.list.rawValue, SettingsText.keyed("settings.choice.tasksList", "List")),
                    SettingChoice(TasksLayoutPreference.board.rawValue, SettingsText.keyed("settings.choice.tasksBoard", "Board")),
                    SettingChoice(TasksLayoutPreference.inbox.rawValue, SettingsText.keyed("settings.choice.tasksInbox", "Inbox")),
                ]),
                default: .string(TasksLayoutSetting().fallback.rawValue),
                keywords: ["tasks", "issues", "board", "list", "inbox", "layout", "kanban"]
            ),
        ]
    }
}
