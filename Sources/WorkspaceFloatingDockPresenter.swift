import AppKit

/// Keeps one main window's native floating Dock windows in sync with its selected workspace.
@MainActor
final class WorkspaceFloatingDockPresenter {
    private weak var parentWindow: NSWindow?
    private weak var tabManager: TabManager?
    private let stashController: WorkspaceFloatingDockStashController
    private var controllers: [UUID: WorkspaceFloatingDockWindowController] = [:]
    private var pendingRestoreAnimationFrames: [UUID: CGRect] = [:]
    private var lastActiveDockId: UUID?

    init(parentWindow: NSWindow, tabManager: TabManager) {
        self.parentWindow = parentWindow
        self.tabManager = tabManager
        stashController = WorkspaceFloatingDockStashController(parentWindow: parentWindow)
    }

    func refresh(
        focusDockId: UUID? = nil,
        placingDockId: UUID? = nil,
        relativeToDockId: UUID? = nil
    ) {
        guard let parentWindow, let tabManager else { return }
        let selectedWorkspace = tabManager.selectedWorkspace
        let activeDocks = selectedWorkspace?.floatingDocks.filter { !$0.isStashed } ?? []
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
                        onStashRequest: { [weak self, weak workspace] dockId in
                            guard let self,
                                  let workspace,
                                  let tabManager = self.tabManager,
                                  let dock = workspace.floatingDock(id: dockId) else { return }
                            _ = AppDelegate.shared?.setWorkspaceFloatingDockStashed(
                                dock,
                                in: workspace,
                                tabManager: tabManager,
                                stashed: true,
                                focus: false
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
                controller.show(
                    focus: focusDockId == dock.id,
                    animatedFrom: pendingRestoreAnimationFrames.removeValue(forKey: dock.id),
                    visibleScreenFrame: stashController.visibleScreenFrame()
                )
            }
        }
        updateStashRail(for: selectedWorkspace)
    }

    func teardown() {
        controllers.values.forEach { $0.teardown() }
        controllers.removeAll()
        stashController.teardown()
        pendingRestoreAnimationFrames.removeAll()
    }

    func animateStash(_ dock: WorkspaceFloatingDock) {
        guard let workspace = tabManager?.selectedWorkspace,
              workspace.floatingDock(id: dock.id) === dock else {
            refresh()
            return
        }
        updateStashRail(for: workspace)
        guard let controller = controllers[dock.id],
              let targetFrame = stashController.animationTargetFrame(for: dock.id),
              let visibleScreenFrame = stashController.visibleScreenFrame() else {
            refresh()
            return
        }
        controller.stash(
            toward: targetFrame,
            visibleScreenFrame: visibleScreenFrame
        ) { [weak self] in
            self?.refresh()
        }
    }

    func prepareRestoreAnimation(for dockId: UUID) {
        updateStashRail(for: tabManager?.selectedWorkspace)
        guard let sourceFrame = stashController.animationTargetFrame(for: dockId) else { return }
        pendingRestoreAnimationFrames[dockId] = sourceFrame
    }

    func beginScreenConfigurationChange() {
        controllers.values.forEach { $0.beginScreenConfigurationChange() }
    }

    @discardableResult
    func reconcileScreenConfiguration() -> Bool {
        stashController.reconcileScreenConfiguration()
        return controllers.values.reduce(true) { reconciled, controller in
            controller.reconcileScreenConfiguration() && reconciled
        }
    }

    func isAttached(to window: NSWindow) -> Bool {
        parentWindow === window
    }

    func owns(window: NSWindow) -> Bool {
        controllers.values.contains { $0.window === window }
            || stashController.owns(window: window)
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
        controllers[dock.id]?.show(
            focus: true,
            visibleScreenFrame: stashController.visibleScreenFrame()
        )
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
           let dock = workspace.floatingDock(id: lastActiveDockId),
           !dock.isStashed {
            return dock
        }
        return workspace.floatingDocks.last(where: { !$0.isStashed })
    }

    private func preferredCascadeSourceDockId(
        in workspace: Workspace,
        excluding dockId: UUID
    ) -> UUID? {
        if let lastActiveDockId,
           lastActiveDockId != dockId,
           workspace.floatingDock(id: lastActiveDockId)?.isStashed == false {
            return lastActiveDockId
        }
        return workspace.floatingDocks.last(where: { $0.id != dockId && !$0.isStashed })?.id
    }

    private func updateStashRail(for workspace: Workspace?) {
        let items = workspace?.floatingDocks
            .filter(\.isStashed)
            .map(stashItem(for:)) ?? []
        stashController.update(items: items) { [weak self, weak workspace] dockId in
            guard let self,
                  let workspace,
                  let tabManager = self.tabManager,
                  let dock = workspace.floatingDock(id: dockId) else { return }
            _ = AppDelegate.shared?.setWorkspaceFloatingDockStashed(
                dock,
                in: workspace,
                tabManager: tabManager,
                stashed: false,
                focus: true
            )
        }
    }

    private func stashItem(for dock: WorkspaceFloatingDock) -> WorkspaceFloatingDockStashItem {
        let panel = dock.store.focusedPanelId.flatMap { dock.store.panels[$0] }
            ?? dock.store.panels.values.first
        let symbolName: String
        if panel === dock.notePanel {
            symbolName = "note.text"
        } else if let displayIcon = panel?.displayIcon {
            symbolName = displayIcon
        } else {
            symbolName = switch panel?.panelType {
            case .terminal: "terminal"
            case .browser: "globe"
            default: "macwindow"
            }
        }
        return WorkspaceFloatingDockStashItem(
            id: dock.id,
            title: dock.title,
            symbolName: symbolName,
            stashedAt: dock.stashedAt ?? 0
        )
    }
}
