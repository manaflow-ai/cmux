import Foundation

extension TabManager {
    @discardableResult
    func openWorkspace(fromSavedLayout layout: CmuxSavedLayout, cwdOverride: String?, focus: Bool) -> Workspace? {
        let baseCwd = FileManager.default.homeDirectoryForCurrentUser.path
        let resolvedCwd = CmuxConfigStore.resolveCwd(cwdOverride ?? layout.workspace.cwd, relativeTo: baseCwd)
        // The initial terminal is a topology placeholder when a declarative
        // layout or setup command replaces or uses it.
        guard let workspace = addWorkspaceIfActive(
            title: layout.workspace.name ?? layout.name,
            workingDirectory: resolvedCwd,
            workspaceEnvironment: layout.workspace.env ?? [:],
            inheritWorkingDirectory: false,
            select: focus,
            initialRuntimeSpawnPolicy: layout.workspace.initialRuntimeSpawnPolicy
        ) else {
            return nil
        }
        if let color = layout.workspace.color {
            setTabColor(tabId: workspace.id, color: color)
        }
        if let layoutNode = layout.workspace.layout {
            workspace.applyCustomLayout(layoutNode, baseCwd: resolvedCwd)
        }
        return workspace
    }
}
