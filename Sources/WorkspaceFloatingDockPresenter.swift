import AppKit

/// Keeps one main window's native floating Dock windows in sync with its selected workspace.
@MainActor
final class WorkspaceFloatingDockPresenter {
    private weak var parentWindow: NSWindow?
    private weak var tabManager: TabManager?
    private var controllers: [UUID: WorkspaceFloatingDockWindowController] = [:]
    private var lastActiveDockId: UUID?
    private var stashedDockOrder: [UUID] = []
    private var revealedStashedDockId: UUID?
    private var isKeyContextVisible = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var parentWindowObserverTokens: [any NSObjectProtocol] = []
    private var lastOwnerVisibleScreenFrame: CGRect?
    private var pendingParkingOwnerVisibleScreenFrame: CGRect?

    init(parentWindow: NSWindow, tabManager: TabManager) {
        self.parentWindow = parentWindow
        self.tabManager = tabManager
        lastOwnerVisibleScreenFrame = parentWindow.screen?.visibleFrame
        isKeyContextVisible = NSApp.isActive && ownsKeyContext(window: NSApp.keyWindow)
        installMouseMonitors()
        installParentWindowObservers()
    }

    func refresh(
        focusDockId: UUID? = nil,
        placingDockId: UUID? = nil,
        relativeToDockId: UUID? = nil
    ) {
        guard let parentWindow, let tabManager else { return }
        _ = updateOwnerScreenTransitionIfNeeded()
        let selectedWorkspace = tabManager.selectedWorkspace
        let workspaceDocks = selectedWorkspace?.floatingDocks ?? []
        let liveIds = Set(workspaceDocks.map(\.id))
        let staleIds = controllers.keys.filter { !liveIds.contains($0) }
        for id in staleIds {
            controllers.removeValue(forKey: id)?.teardown()
        }

        if let workspace = selectedWorkspace {
            for dock in workspaceDocks {
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
                        onRestoreRequest: { [weak self, weak workspace] dockId in
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
                        },
                        onBecomeKey: { [weak self] dockId in
                            self?.lastActiveDockId = dockId
                        },
                        onRenameRequest: { [weak self, weak workspace] dockId, title in
                            guard let self,
                                  let workspace,
                                  let tabManager = self.tabManager,
                                  let dock = workspace.floatingDock(id: dockId) else {
                                return false
                            }
                            return AppDelegate.shared?.renameWorkspaceFloatingDock(
                                dock,
                                in: workspace,
                                tabManager: tabManager,
                                title: title
                            ) == true
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
            }
            guard isKeyContextVisible else {
                hideForInactiveKeyContext()
                return
            }
            for dock in workspaceDocks where !dock.isStashed {
                controllers[dock.id]?.show(focus: focusDockId == dock.id)
            }
            applyParkingLayout(
                to: workspace.stashedFloatingDocksInParkingOrder,
                animatedDockId: nil
            )
        } else {
            stashedDockOrder.removeAll()
            revealedStashedDockId = nil
        }
    }

    func updateKeyContext(keyWindow: NSWindow?, applicationIsActive: Bool) {
        let nextIsVisible = applicationIsActive && ownsKeyContext(window: keyWindow)
        guard nextIsVisible != isKeyContextVisible else { return }
        isKeyContextVisible = nextIsVisible
        if nextIsVisible {
            refresh()
        } else {
            hideForInactiveKeyContext()
        }
    }

    func teardown() {
        controllers.values.forEach { $0.teardown() }
        controllers.removeAll()
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        for token in parentWindowObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        parentWindowObserverTokens.removeAll()
        stashedDockOrder.removeAll()
        revealedStashedDockId = nil
        pendingParkingOwnerVisibleScreenFrame = nil
    }

    func animateStash(_ dock: WorkspaceFloatingDock) {
        guard let workspace = tabManager?.selectedWorkspace,
              workspace.floatingDock(id: dock.id) === dock else {
            refresh()
            return
        }
        guard controllers[dock.id] != nil else {
            refresh()
            return
        }
        applyParkingLayout(
            to: workspace.stashedFloatingDocksInParkingOrder,
            animatedDockId: dock.id
        ) { [weak self] in
            self?.refresh()
        }
    }

    func animateParkingReorder() {
        guard let workspace = tabManager?.selectedWorkspace else { return }
        applyParkingLayout(
            to: workspace.stashedFloatingDocksInParkingOrder,
            animatedDockId: nil,
            animatesLayout: true
        )
    }

    func beginScreenConfigurationChange() {
        controllers.values.forEach { $0.beginScreenConfigurationChange() }
    }

    @discardableResult
    func reconcileScreenConfiguration() -> Bool {
        _ = updateOwnerScreenTransitionIfNeeded()
        let reconciled = controllers.values.reduce(true) { reconciled, controller in
            controller.reconcileScreenConfiguration() && reconciled
        }
        if reconciled, let workspace = tabManager?.selectedWorkspace {
            applyParkingLayout(
                to: workspace.stashedFloatingDocksInParkingOrder,
                animatedDockId: nil
            )
        }
        return reconciled
    }

    func isAttached(to window: NSWindow) -> Bool {
        parentWindow === window
    }

    func owns(window: NSWindow) -> Bool {
        controllers.values.contains { $0.owns(window: window) }
    }

    func dockId(owning window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return controllers.first(where: { $0.value.owns(window: window) })?.key
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

    func window(for dock: WorkspaceFloatingDock) -> NSWindow? {
        controllers[dock.id]?.window
    }

    func focus(_ dock: WorkspaceFloatingDock) {
        guard isKeyContextVisible else { return }
        controllers[dock.id]?.show(focus: true)
    }

    func beginRenaming(_ dock: WorkspaceFloatingDock) {
        guard isKeyContextVisible,
              let workspace = tabManager?.selectedWorkspace,
              workspace.floatingDock(id: dock.id) === dock,
              let controller = controllers[dock.id] else { return }
        if dock.isStashed {
            revealedStashedDockId = dock.id
        }
        controller.beginRenaming()
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

    func preferredDockForNaming(in workspace: Workspace) -> WorkspaceFloatingDock? {
        if let keyWindow = NSApp.keyWindow,
           let dockId = dockId(owning: keyWindow),
           let dock = workspace.floatingDock(id: dockId) {
            return dock
        }
        return preferredDock(in: workspace) ?? preferredStashedDock(in: workspace)
    }

    func preferredStashedDock(in workspace: Workspace) -> WorkspaceFloatingDock? {
        if let revealedStashedDockId,
           let dock = workspace.floatingDock(id: revealedStashedDockId),
           dock.isStashed {
            return dock
        }
        return workspace.stashedFloatingDocksInVisualOrder.first
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

    private func applyParkingLayout(
        to docks: [WorkspaceFloatingDock],
        animatedDockId: UUID?,
        animatesLayout: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard isKeyContextVisible else {
            hideForInactiveKeyContext()
            completion?()
            return
        }
        guard let fallbackVisibleScreenFrame = visibleScreenFrame() else {
            docks.forEach { controllers[$0.id]?.hide() }
            stashedDockOrder.removeAll()
            revealedStashedDockId = nil
            completion?()
            return
        }

        let liveIds = Set(docks.map(\.id))
        if let revealedStashedDockId, !liveIds.contains(revealedStashedDockId) {
            controllers[revealedStashedDockId]?.setParkingRevealed(false)
            self.revealedStashedDockId = nil
        }

        var entries: [(
            dock: WorkspaceFloatingDock,
            controller: WorkspaceFloatingDockWindowController,
            restoreFrame: CGRect,
            visibleScreenFrame: CGRect
        )] = []
        entries.reserveCapacity(docks.count)
        let migrationTarget = pendingParkingOwnerVisibleScreenFrame
        let availableScreenFrames = NSScreen.screens.map(\.frame)
        for dock in docks {
            guard let controller = controllers[dock.id],
                  let request = controller.parkingRequest(
                    fallbackVisibleScreenFrame: fallbackVisibleScreenFrame,
                    migratingToVisibleScreenFrame: migrationTarget,
                    availableScreenFrames: availableScreenFrames
                  ) else {
                controllers[dock.id]?.hide()
                continue
            }
            entries.append((
                dock: dock,
                controller: controller,
                restoreFrame: request.restoreFrame,
                visibleScreenFrame: request.visibleScreenFrame
            ))
        }
        pendingParkingOwnerVisibleScreenFrame = nil
        stashedDockOrder = entries.map { $0.dock.id }

        var didStartRequestedAnimation = false
        var remainingEntries = entries
        while let first = remainingEntries.first {
            let screenFrame = first.visibleScreenFrame
            let group = remainingEntries.filter { $0.visibleScreenFrame == screenFrame }
            remainingEntries.removeAll { $0.visibleScreenFrame == screenFrame }
            let snapshots = WorkspaceFloatingDockParkingSnapshot.arranged(
                restoreFrames: group.map(\.restoreFrame),
                visibleScreenFrame: screenFrame,
                availableScreenFrames: availableScreenFrames
            )
            for (entry, snapshot) in zip(group, snapshots) {
#if DEBUG
                cmuxDebugLog(
                    "floating.parking.layout dock=\(entry.dock.id.uuidString.prefix(5)) " +
                    "restore=\(NSStringFromRect(entry.restoreFrame)) " +
                    "screen=\(NSStringFromRect(screenFrame)) " +
                    "parked=\(NSStringFromRect(snapshot.parkedFrame))"
                )
#endif
                if entry.dock.id == animatedDockId {
                    didStartRequestedAnimation = true
                    entry.controller.stash(snapshot: snapshot) {
                        completion?()
                    }
                } else {
                    entry.controller.showStashed(
                        snapshot: snapshot,
                        animated: animatesLayout || animatedDockId != nil
                    )
                }
            }
        }

        for dockId in stashedDockOrder {
            controllers[dockId]?.setParkingRevealed(dockId == revealedStashedDockId)
        }
        orderStashedWindows()
        if animatedDockId != nil, !didStartRequestedAnimation {
            completion?()
        }
    }

    private func orderStashedWindows() {
        guard isKeyContextVisible else { return }
        stashedDockOrder.forEach { controllers[$0]?.orderStashedWindowFront() }
    }

    private func visibleScreenFrame() -> CGRect? {
        parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func installMouseMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.updateStashedWindowHover()
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStashedWindowHover()
            }
        }
    }

    private func installParentWindowObservers() {
        guard let parentWindow else { return }
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.updateOwnerScreenTransitionIfNeeded() {
                    self.refresh()
                }
            }
        }
        parentWindowObserverTokens = [
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: parentWindow,
                queue: .main,
                using: handler
            ),
            // AppKit normally posts didChangeScreen, while didMove covers
            // windows crossing a display boundary during unusual live moves.
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: parentWindow,
                queue: .main,
                using: handler
            ),
        ]
    }

    @discardableResult
    private func updateOwnerScreenTransitionIfNeeded() -> Bool {
        guard let parentWindow,
              let nextVisibleScreenFrame = parentWindow.screen?.visibleFrame else { return false }
        guard let previousVisibleScreenFrame = lastOwnerVisibleScreenFrame else {
            lastOwnerVisibleScreenFrame = nextVisibleScreenFrame
            return false
        }
        guard previousVisibleScreenFrame != nextVisibleScreenFrame else { return false }

        lastOwnerVisibleScreenFrame = nextVisibleScreenFrame
        pendingParkingOwnerVisibleScreenFrame = nextVisibleScreenFrame
        migrateUnpresentedWorkspaceDocks(
            from: previousVisibleScreenFrame,
            to: nextVisibleScreenFrame
        )
        return true
    }

    private func migrateUnpresentedWorkspaceDocks(
        from previousOwnerVisibleScreenFrame: CGRect,
        to targetVisibleScreenFrame: CGRect
    ) {
        guard let parentWindow,
              let tabManager,
              let appDelegate = AppDelegate.shared else { return }
        let presentedDockIds = Set(controllers.keys)
        let signature = appDelegate.currentDisplayConfigurationSignature()
        let targetDisplaySnapshot = appDelegate.displaySnapshot(for: parentWindow.screen)

        for dock in tabManager.tabs.lazy.flatMap(\.floatingDocks)
            where !presentedDockIds.contains(dock.id) {
            let remembered = signature.flatMap(dock.configFrames.entry(for:))
            guard let sourceFrame = remembered?.frame.cgRect ?? dock.screenFrame else {
                // A never-presented Dock has only a parent-relative frame. Its
                // first controller will resolve that frame against the new owner.
                continue
            }
            let sourceVisibleScreenFrame = remembered?.display?.visibleFrame?.cgRect
                ?? dock.displaySnapshot?.visibleFrame?.cgRect
                ?? previousOwnerVisibleScreenFrame
            let migratedFrame = WorkspaceFloatingDockScreenPlacement
                .remappedFramePreservingSize(
                    sourceFrame,
                    from: sourceVisibleScreenFrame,
                    to: targetVisibleScreenFrame
                )
            dock.recordScreenPlacement(
                migratedFrame,
                relativeTo: parentWindow.frame,
                displaySnapshot: targetDisplaySnapshot,
                configurationSignature: signature
            )
        }
    }

    private func updateStashedWindowHover() {
        guard isKeyContextVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        let nextRevealedDockId: UUID?
        if let revealedStashedDockId,
           controllers[revealedStashedDockId]?.containsParkingRevealedPoint(mouseLocation) == true {
            nextRevealedDockId = revealedStashedDockId
        } else {
            nextRevealedDockId = stashedDockOrder.reversed().first {
                controllers[$0]?.containsParkingRestingPoint(mouseLocation) == true
            }
        }
        guard nextRevealedDockId != revealedStashedDockId else { return }

        if let revealedStashedDockId {
            controllers[revealedStashedDockId]?.setParkingRevealed(false)
        }
        revealedStashedDockId = nextRevealedDockId
        if let nextRevealedDockId {
            controllers[nextRevealedDockId]?.setParkingRevealed(true)
        }
    }

    private func ownsKeyContext(window: NSWindow?) -> Bool {
        var candidate = window
        while let currentWindow = candidate {
            if currentWindow === parentWindow || owns(window: currentWindow) {
                return true
            }
            candidate = currentWindow.parent
        }
        return false
    }

    private func hideForInactiveKeyContext() {
        revealedStashedDockId = nil
        stashedDockOrder.removeAll()
        controllers.values.forEach { $0.hideForInactiveKeyContext() }
    }
}
