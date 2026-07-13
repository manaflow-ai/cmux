import Foundation

extension TabManager {
    @discardableResult
    func openWorkspace(fromSavedLayout layout: CmuxSavedLayout, cwdOverride: String?, focus: Bool) -> Workspace? {
        let baseCwd = FileManager.default.homeDirectoryForCurrentUser.path
        let resolvedCwd = CmuxConfigStore.resolveCwd(cwdOverride ?? layout.workspace.cwd, relativeTo: baseCwd)
        let workspace = addWorkspace(
            title: layout.workspace.name ?? layout.name,
            workingDirectory: resolvedCwd,
            workspaceEnvironment: layout.workspace.env ?? [:],
            inheritWorkingDirectory: false,
            select: focus
        )
        if let color = layout.workspace.color {
            workspace.setCustomColor(color)
        }
        if let layoutNode = layout.workspace.layout {
            workspace.applyCustomLayout(layoutNode, baseCwd: resolvedCwd)
        }
        return workspace
    }
}
