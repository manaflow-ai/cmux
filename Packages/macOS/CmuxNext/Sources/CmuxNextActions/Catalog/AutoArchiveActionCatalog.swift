// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): the sweep, the Archived list and a group's
// own rule. Bound by CmuxNextSidebarActions' AutoArchiveActions. Titles live in WorkspaceActions.xcstrings.

nonisolated enum AutoArchiveActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "workspace.archiveIdle", title: t("action.autoArchive.archiveIdle", "Archive Idle Workspaces"),
                keywords: ["archive", "idle", "old", "stale", "tidy", "clean up", "declutter", "workspaces", "sweep"],
                category: .workspace, symbol: "archivebox", surfaces: [.palette, .contextMenu], cliName: "workspace archive-idle"
            ),
            ActionDescriptor(
                id: "workspace.showArchived", title: t("action.autoArchive.showArchived", "Show Archived Workspaces…"),
                keywords: ["archive", "archived", "restore", "unarchive", "find", "search", "workspaces"],
                category: .workspace, symbol: "archivebox.circle", surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "workspaceGroup.setAutoArchive", title: t("action.autoArchive.setGroupRule", "Auto-Archive Group Workspaces"),
                keywords: ["group", "archive", "auto archive", "idle", "rule", "never", "days"], category: .workspace,
                symbol: "archivebox", surfaces: [.palette, .contextMenu], arguments: [ruleChoice], targets: [.workspaceGroup],
                cliName: "workspace-group set-auto-archive"
            ),
        ]
    }

    /// A group's rule: the setting's default, never, or after this many idle hours (the reducer
    /// takes 1 to 87 600 hours; the menu offers the common ones, the CLI any).
    static var ruleChoice: ActionArgument {
        ActionArgument(name: "after", title: t("argument.autoArchive.after", "Archive Members"), kind: .enumeration([
            ActionEnumCase(value: "default", title: t("argument.value.autoArchive.default", "Use the Default")),
            ActionEnumCase(value: "never", title: t("argument.value.autoArchive.never", "Never")),
            ActionEnumCase(value: "24", title: t("argument.value.autoArchive.day", "After 1 Idle Day")),
            ActionEnumCase(value: "72", title: t("argument.value.autoArchive.threeDays", "After 3 Idle Days")),
            ActionEnumCase(value: "168", title: t("argument.value.autoArchive.week", "After 1 Idle Week")),
            ActionEnumCase(value: "720", title: t("argument.value.autoArchive.month", "After 30 Idle Days")),
        ]))
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "WorkspaceActions", bundle: .module)
    }
}
