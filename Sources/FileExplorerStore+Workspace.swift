import Foundation

extension FileExplorerStore {
    /// Shared by the right sidebar and tool panes; owns Cloud observation and retry.
    func syncWorkspaceRoot(from workspace: Workspace) {
        if workspaceRootObservation?.workspace !== workspace {
            workspaceRootObservation?.stop()
            workspaceRootObservation = FileExplorerWorkspaceObservation(
                workspace: workspace, resolver: FileExplorerWorkspaceRootResolver(),
                apply: { [weak self] in self?.applyWorkspaceRoot($0) }
            )
        }
        workspaceRootObservation?.refresh()
    }

    func retryRemoteRoot() {
        if let observation = workspaceRootObservation {
            observation.refresh(force: true)
        }
        if !rootPath.isEmpty { reload() }
        if let target = (provider as? CloudVMFileExplorerProvider)?.target, !target.isCurrent() {
            setRootStatusMessage(String(localized: "fileExplorer.status.cloudDisconnected",
                defaultValue: "Cloud machine is not connected"))
        }
    }
}
