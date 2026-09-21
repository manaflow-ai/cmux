import Foundation

extension SurfaceCatalog.NewWorkspaceHost {
    /// Captures the originating manager so later window focus cannot redirect creation.
    @MainActor
    init(tabManager: TabManager) {
        self = .appOptimistic
        create = { [weak tabManager] title in
            guard let tabManager,
                  let workspace = tabManager.addWorkspaceIfActive(
                    title: title, titleSource: .auto, initialSurface: .cloudVMLoading,
                    inheritWorkingDirectory: false, select: false, autoWelcomeIfNeeded: false
                  ) else { throw CancellationError() }
            return (workspace.id, workspace.focusedPanelId)
        }
    }
}
