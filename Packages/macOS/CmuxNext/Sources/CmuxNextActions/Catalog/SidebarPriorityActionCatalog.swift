// The sidebar's Priority view (`sidebar.priorityView.*`): its bell, and what a row does to its
// chat. A row's hover buttons and right-click menu run these (the archive button runs Archive
// Chat on the row's chat), so the palette, a shortcut and the menu share one path. Titles live in
// SidebarSectionActions.xcstrings. The marks are this Mac's view state: no CLI verb.

nonisolated enum SidebarPriorityActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let chat: [ActionTargetKind] = [.agentChat]
        return [
            // The Priority view's bell (`sidebar.priorityView.shown`), while the view is installed.
            ActionDescriptor(
                id: "sidebar.priorityView.toggle", title: t("action.sidebar.priorityView.toggle", "Toggle Priority View"),
                keywords: ["sidebar", "priority", "activity", "attention", "agents", "chats", "needs you", "bell"],
                defaultShortcut: Shortcut("k", modifiers: [.option, .command]), category: .sidebar, symbol: "bell",
                surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            // A row's actions: from the palette they ask which chat (the Priority view's rows), so their
            // titles end in "…"; the row's menu names its chat and drops the "…" and the noun.
            ActionDescriptor(
                id: "sidebar.priority.markRead", title: t("action.sidebar.priority.markRead", "Mark Chat as Read…"),
                keywords: ["sidebar", "priority", "chat", "agent", "read", "seen", "done", "clear"],
                category: .sidebar, symbol: "checkmark.circle", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [chatArgument], targets: chat,
                surfacePlan: rowPlan(.identity, 0, label: t("menu.sidebar.priority.markRead", "Mark as Read"))
            ),
            ActionDescriptor(
                id: "sidebar.priority.togglePin", title: t("action.sidebar.priority.togglePin", "Pin/Unpin Chat in Priority…"),
                keywords: ["sidebar", "priority", "chat", "agent", "pin", "unpin", "keep", "top"],
                category: .sidebar, symbol: "pin", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [chatArgument], targets: chat, surfacePlan: rowPlan(.identity, 10)
            ),
            ActionDescriptor(
                id: "sidebar.priority.snooze", title: t("action.sidebar.priority.snooze", "Snooze Chat for 1 Hour…"),
                keywords: ["sidebar", "priority", "chat", "agent", "snooze", "later", "hide", "mute"],
                category: .sidebar, symbol: "moon.zzz", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [chatArgument], targets: chat,
                surfacePlan: rowPlan(.identity, 20, label: t("menu.sidebar.priority.snooze", "Snooze for 1 Hour"))
            ),
        ]
    }

    /// The row's chat; a right-click or a hover button supplies it, the palette lists the rows.
    private static var chatArgument: ActionArgument {
        ActionArgument(name: "chat", title: t("argument.sidebar.priority.chat", "Chat"), kind: .target(.agentChat)).suppliedByTarget
    }

    /// A row menu placement; `label` is the row's shorter title there (Pin/Unpin takes the chat's
    /// Pin or Unpin from `ActionTargetTitles`).
    private static func rowPlan(_ group: MenuGroup, _ rank: Int, label: String? = nil) -> ActionSurfacePlan {
        ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [ContextMenuPlacement(.priorityRow, group, rank, label: label)])
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "SidebarSectionActions", bundle: .module)
    }
}
