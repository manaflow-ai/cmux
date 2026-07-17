import AppKit

/// Keeps one main window's native floating Dock windows in sync with its selected workspace.
@MainActor
final class WorkspaceFloatingDockPresenter {
    private weak var parentWindow: NSWindow?
    private weak var tabManager: TabManager?
    private var controllers: [UUID: WorkspaceFloatingDockWindowController] = [:]

    init(parentWindow: NSWindow, tabManager: TabManager) {
        self.parentWindow = parentWindow
        self.tabManager = tabManager
    }

    func refresh(focusDockId: UUID? = nil) {
        guard let parentWindow, let tabManager else { return }
        tabManager.selectedWorkspace?.ensureFloatingDockConfigurationLoaded()
        let allDocks = tabManager.tabs.flatMap(\.floatingDocks)
        let liveIds = Set(allDocks.map(\.id))
        let staleIds = controllers.keys.filter { !liveIds.contains($0) }
        for id in staleIds {
            controllers.removeValue(forKey: id)?.teardown()
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs {
            for dock in workspace.floatingDocks {
                let controller = controllers[dock.id] ?? {
                    let created = WorkspaceFloatingDockWindowController(
                        dock: dock,
                        parentWindow: parentWindow,
                        onCloseRequest: { [weak self, weak workspace] dockId in
                            guard let workspace else { return }
                            _ = workspace.closeFloatingDock(id: dockId)
                            self?.refresh()
                        }
                    )
                    controllers[dock.id] = created
                    return created
                }()
                if workspace.id == selectedWorkspaceId, dock.isPresented {
                    controller.show(focus: focusDockId == dock.id)
                } else {
                    controller.hide()
                }
            }
        }
    }

    func teardown() {
        controllers.values.forEach { $0.teardown() }
        controllers.removeAll()
    }

    func isAttached(to window: NSWindow) -> Bool {
        parentWindow === window
    }
}
