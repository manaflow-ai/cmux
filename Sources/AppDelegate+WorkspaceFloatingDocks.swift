import AppKit

extension AppDelegate.MainWindowContext {
    func installWorkspaceFloatingDockPresenterIfNeeded() {
        guard let window else { return }
        if let workspaceFloatingDockPresenter,
           workspaceFloatingDockPresenter.isAttached(to: window) {
            return
        }
        workspaceFloatingDockPresenter?.teardown()
        workspaceFloatingDockPresenter = WorkspaceFloatingDockPresenter(
            parentWindow: window,
            tabManager: tabManager
        )
    }

    func teardownWorkspaceFloatingDockPresenter() {
        workspaceFloatingDockPresenter?.teardown()
        workspaceFloatingDockPresenter = nil
    }
}

extension AppDelegate {
    @discardableResult
    func createWorkspaceFloatingDock(
        in tabManager: TabManager,
        title: String? = nil,
        focus: Bool
    ) -> WorkspaceFloatingDock? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        guard let dock = workspace.createFloatingDock(title: title) else { return nil }
        refreshWorkspaceFloatingDocks(for: tabManager, focusDockId: focus ? dock.id : nil)
        return dock
    }

    func refreshWorkspaceFloatingDocks(
        for tabManager: TabManager,
        focusDockId: UUID? = nil
    ) {
        guard let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else { return }
        context.installWorkspaceFloatingDockPresenterIfNeeded()
        context.workspaceFloatingDockPresenter?.refresh(focusDockId: focusDockId)
    }

    func refreshAllWorkspaceFloatingDocks() {
        for context in mainWindowContexts.values {
            context.installWorkspaceFloatingDockPresenterIfNeeded()
            context.workspaceFloatingDockPresenter?.refresh()
        }
    }
}
