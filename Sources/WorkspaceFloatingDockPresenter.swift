import AppKit

/// Keeps one main window's native floating Dock windows in sync with its selected workspace.
@MainActor
final class WorkspaceFloatingDockPresenter {
    private weak var parentWindow: NSWindow?
    private weak var tabManager: TabManager?
    private var controllers: [UUID: WorkspaceFloatingDockWindowController] = [:]
    private var lastActiveDockId: UUID?

    init(parentWindow: NSWindow, tabManager: TabManager) {
        self.parentWindow = parentWindow
        self.tabManager = tabManager
    }

    func refresh(
        focusDockId: UUID? = nil,
        placingDockId: UUID? = nil,
        relativeToDockId: UUID? = nil
    ) {
        guard let parentWindow, let tabManager else { return }
        let selectedWorkspace = tabManager.selectedWorkspace
        let activeDocks = selectedWorkspace?.floatingDocks.filter(\.isPresented) ?? []
        let liveIds = Set(activeDocks.map(\.id))
        let staleIds = controllers.keys.filter { !liveIds.contains($0) }
        for id in staleIds {
            controllers.removeValue(forKey: id)?.teardown()
        }

        if let workspace = selectedWorkspace {
            for dock in activeDocks {
                let wasCreated = controllers[dock.id] == nil
                let controller = controllers[dock.id] ?? {
                    let created = WorkspaceFloatingDockWindowController(
                        dock: dock,
                        parentWindow: parentWindow,
                        onCloseRequest: { [weak self, weak workspace] dockId in
                            guard let self,
                                  let workspace,
                                  let tabManager = self.tabManager,
                                  let dock = workspace.floatingDock(id: dockId) else { return }
                            _ = AppDelegate.shared?.closeWorkspaceFloatingDock(
                                dock,
                                in: workspace,
                                tabManager: tabManager
                            )
                        },
                        onMinimizeRequest: { [weak self, weak workspace] dockId in
                            guard let self,
                                  let tabManager = self.tabManager,
                                  let workspace,
                                  let dock = workspace.floatingDock(id: dockId) else { return }
                            _ = AppDelegate.shared?.setWorkspaceFloatingDockPresented(
                                dock,
                                in: workspace,
                                tabManager: tabManager,
                                presented: false,
                                focus: false
                            )
                        },
                        onCreateRequest: { [weak self] in
                            guard let tabManager = self?.tabManager else { return }
                            _ = AppDelegate.shared?.createWorkspaceFloatingDock(
                                in: tabManager,
                                focus: true
                            )
                        },
                        onBecomeKey: { [weak self] dockId in
                            self?.lastActiveDockId = dockId
                        }
                    )
                    controllers[dock.id] = created
                    return created
                }()
                if wasCreated, placingDockId == dock.id {
                    let sourceDockId = relativeToDockId
                        ?? preferredCascadeSourceDockId(in: workspace, excluding: dock.id)
                    if let sourceDockId,
                       let sourceWindow = controllers[sourceDockId]?.window {
                        controller.cascade(relativeTo: sourceWindow)
                    }
                }
                controller.show(focus: focusDockId == dock.id)
            }
        }
    }

    func teardown() {
        controllers.values.forEach { $0.teardown() }
        controllers.removeAll()
    }

    func beginScreenConfigurationChange() {
        controllers.values.forEach { $0.beginScreenConfigurationChange() }
    }

    @discardableResult
    func reconcileScreenConfiguration() -> Bool {
        controllers.values.reduce(true) { reconciled, controller in
            controller.reconcileScreenConfiguration() && reconciled
        }
    }

    func isAttached(to window: NSWindow) -> Bool {
        parentWindow === window
    }

    func owns(window: NSWindow) -> Bool {
        controllers.values.contains { $0.window === window }
    }

    func dockId(owning window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return controllers.first(where: { $0.value.window === window })?.key
    }

    func dock(owning window: NSWindow?) -> WorkspaceFloatingDock? {
        guard let tabManager,
              let dockId = dockId(owning: window) else { return nil }
        return tabManager.tabs.lazy.compactMap { $0.floatingDock(id: dockId) }.first
    }

    func dock(owning store: DockSplitStore) -> WorkspaceFloatingDock? {
        guard let tabManager else { return nil }
        return tabManager.tabs.lazy.flatMap(\.floatingDocks).first { $0.store === store }
    }

    func focus(_ dock: WorkspaceFloatingDock) {
        controllers[dock.id]?.show(focus: true)
    }

    func updateTint(for dock: WorkspaceFloatingDock) {
        controllers[dock.id]?.updateTintInPlace()
    }

    func preferredDock(in workspace: Workspace) -> WorkspaceFloatingDock? {
        if let keyWindow = NSApp.keyWindow,
           let dockId = dockId(owning: keyWindow),
           let dock = workspace.floatingDock(id: dockId) {
            return dock
        }
        if let lastActiveDockId,
           let dock = workspace.floatingDock(id: lastActiveDockId) {
            return dock
        }
        return workspace.floatingDocks.last
    }

    private func preferredCascadeSourceDockId(
        in workspace: Workspace,
        excluding dockId: UUID
    ) -> UUID? {
        if let lastActiveDockId,
           lastActiveDockId != dockId,
           workspace.floatingDock(id: lastActiveDockId) != nil {
            return lastActiveDockId
        }
        return workspace.floatingDocks.last(where: { $0.id != dockId })?.id
    }
}
