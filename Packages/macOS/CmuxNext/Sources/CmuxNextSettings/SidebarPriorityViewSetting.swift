public import CmuxNextDesign

/// `sidebar.priorityView.enabled` and `sidebar.priorityView.shown` in cmux.json: the Priority view
/// at the top of the sidebar (every agent chat, the ones that need you first). `enabled` is the
/// App Store item's switch, off by default; `shown` is the titlebar bell's state while it is on.
public nonisolated struct SidebarPriorityViewSetting {
    public nonisolated init() {}
    public static let enabledPath = ["sidebar", "priorityView", "enabled"]
    public static let shownPath = ["sidebar", "priorityView", "shown"]

    static func descriptors(group: SettingText) -> [SettingDescriptor] {
        [
            SettingDescriptor(enabledPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.priorityView.enabled", "Priority View"),
                              help: SettingsText.keyed("settings.sidebar.priorityView.enabled.help",
                                                       "A bell at the top of the sidebar shows every agent chat on every machine, the ones waiting on you first, then finished, failed, working and idle."),
                              summary: SettingsText.keyed("settings.sidebar.priorityView.enabled.summary", "Agent chats that need you, at the top of the sidebar"),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.priorityViewEnabled),
                              keywords: ["sidebar", "priority", "attention", "agents", "chats", "needs you", "activity", "bell", "inbox"]),
            SettingDescriptor(shownPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.priorityView.shown", "Show Priority View"),
                              help: SettingsText.keyed("settings.sidebar.priorityView.shown.help",
                                                       "The sidebar bell's state while the Priority view is on. Off, the sidebar is unchanged."),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.priorityViewShown),
                              keywords: ["sidebar", "priority", "activity", "bell", "show", "hide"]),
        ]
    }
}
