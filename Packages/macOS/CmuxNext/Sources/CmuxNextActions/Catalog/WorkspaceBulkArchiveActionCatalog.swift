// The archive counterparts of the workspace row's several-at-once closes (user, 2026-11-05: "we need
// archive workspaces below/above etc"): the same rows as Close Other Workspaces, Close Other Workspaces
// in Group, Close Workspaces Below and Above, archived (plans/cmux-next/archiving-DESIGN.md) instead of
// closed. Pinned rows stay; one undo step brings the batch back. Bound by CmuxNextSidebarActions'
// WorkspaceBulkArchiveActions. Titles live in WorkspaceActions.xcstrings.

nonisolated enum WorkspaceBulkArchiveActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "workspace.archiveOtherWorkspaces", title: t("action.workspace.archiveOtherWorkspaces", "Archive Other Workspaces"),
                keywords: ["archive", "others", "tidy", "declutter", "hide"], category: .workspace, symbol: "archivebox",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace archive-other"
            ),
            ActionDescriptor(
                id: "workspace.archiveOthersInGroup",
                title: t("action.workspace.archiveOthersInGroup", "Archive Other Workspaces in Group"),
                keywords: ["archive", "others", "group", "tidy", "declutter"], category: .workspace, symbol: "archivebox",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace archive-others-in-group"
            ),
            ActionDescriptor(
                id: "workspace.archiveWorkspacesBelow", title: t("action.workspace.archiveWorkspacesBelow", "Archive Workspaces Below"),
                keywords: ["archive", "below", "under", "after", "tidy", "declutter"], category: .workspace, symbol: "arrow.down.to.line",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace archive-below"
            ),
            ActionDescriptor(
                id: "workspace.archiveWorkspacesAbove", title: t("action.workspace.archiveWorkspacesAbove", "Archive Workspaces Above"),
                keywords: ["archive", "above", "over", "before", "tidy", "declutter"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace archive-above"
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "WorkspaceActions", bundle: .module)
    }
}
