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
                id: "workspace.restoreArchived", title: t("action.autoArchive.restoreArchived", "Restore Archived Workspace…"),
                keywords: ["archive", "archived", "restore", "unarchive", "find", "search", "workspaces", "show archived"],
                category: .workspace, symbol: "archivebox.circle", surfaces: [.palette, .contextMenu], arguments: [archivedChoice],
                cliName: "workspace restore-archived"
            ),
            ActionDescriptor(
                id: "workspaceGroup.setAutoArchive", title: t("action.autoArchive.setGroupRule", "Auto-Archive Group Workspaces"),
                keywords: ["group", "archive", "auto archive", "idle", "rule", "never", "days"], category: .workspace,
                symbol: "archivebox", surfaces: [.palette, .contextMenu], arguments: [ruleChoice], targets: [.workspaceGroup],
                cliName: "workspace-group set-auto-archive"
            ),
            // DEV only: makes every workspace look `days` older and runs a pass (the gallery tours).
            ActionDescriptor(
                id: "debug.autoArchive.age", title: t("action.autoArchive.debugAge", "Age Workspaces for Auto-Archive"),
                keywords: ["archive", "idle", "debug", "age", "clock"], category: .workspace, symbol: "clock.arrow.circlepath",
                surfaces: [.palette],
                arguments: [ActionArgument(name: "days", title: t("argument.autoArchive.days", "Days"), kind: .string, isRequired: false)],
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    /// The archived workspace to restore (a document item), or `all`; the palette lists them.
    static var archivedChoice: ActionArgument {
        ActionArgument(name: "item", title: t("argument.autoArchive.item", "Archived Workspace"), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.archivedWorkspaces, pinned: [
                           ActionEnumCase(value: "all", title: t("argument.value.autoArchive.restoreAll", "Restore All")),
                       ]))
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
