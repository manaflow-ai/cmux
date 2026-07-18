import Foundation

extension TabManager {
    @discardableResult
    func openWorkspace(
        fromSavedLayout layout: CmuxSavedLayout,
        cwdOverride: String?,
        focus: Bool
    ) -> WorkspaceCreationOutcome {
        let baseCwd = FileManager.default.homeDirectoryForCurrentUser.path
        let resolvedCwd = CmuxConfigStore.resolveCwd(cwdOverride ?? layout.workspace.cwd, relativeTo: baseCwd)
        if layout.workspace.layout != nil,
           let mutationCoordinator = terminalClientComposition
            .terminalBackendTopologyMutationCoordinator {
            mutationCoordinator.reportFailure(for: .splitPane)
            return .failed
        }
        let configureWorkspace: @MainActor (Workspace) -> Void = { workspace in
            if let color = layout.workspace.color {
                workspace.setCustomColor(color)
            }
            if let layoutNode = layout.workspace.layout {
                workspace.applyCustomLayout(layoutNode, baseCwd: resolvedCwd)
            }
        }
        let outcome = requestAddWorkspace(
            title: layout.workspace.name ?? layout.name,
            workingDirectory: resolvedCwd,
            workspaceEnvironment: layout.workspace.env ?? [:],
            inheritWorkingDirectory: false,
            select: focus,
            onProjected: configureWorkspace
        )
        if case .created(let workspace) = outcome {
            configureWorkspace(workspace)
        }
        return outcome
    }
}
