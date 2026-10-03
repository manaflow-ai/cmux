extension SettingsSchema {
    /// The Tasks pane (plans/cmux-next/tasks.md section 9).
    static var tasks: [SettingDescriptor] {
        let group = SettingsText.text("settings.group.tasks", "Tasks")
        return [
            SettingDescriptor(
                TasksLayoutSetting.configPath, section: .general, group: group,
                title: SettingsText.text("settings.tasks.layout", "Tasks Layout"),
                help: SettingsText.text("settings.tasks.layout.help",
                                        "Inbox lists what needs you first, with the task beside it. Changes apply at once."),
                kind: .choice([
                    SettingChoice(TasksLayoutPreference.list.rawValue, SettingsText.text("settings.choice.tasksList", "List")),
                    SettingChoice(TasksLayoutPreference.board.rawValue, SettingsText.text("settings.choice.tasksBoard", "Board")),
                    SettingChoice(TasksLayoutPreference.inbox.rawValue, SettingsText.text("settings.choice.tasksInbox", "Inbox")),
                ]),
                default: .string(TasksLayoutSetting.fallback.rawValue),
                keywords: ["tasks", "issues", "board", "list", "inbox", "layout", "kanban"]
            ),
        ]
    }
}
