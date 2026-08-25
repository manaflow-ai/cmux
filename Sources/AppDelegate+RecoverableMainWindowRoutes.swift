import AppKit
import CmuxTerminalCore
import CmuxTerminal

// The retire sweep is the MainWindowRouteRetiring witness: the terminal
// surface registry (CmuxTerminalEngine) calls it through the seam instead of
// reaching up to AppDelegate.shared.
extension AppDelegate: MainWindowRouteRetiring {}

extension AppDelegate {
    private func tabManagerHasRegisteredTerminalSurface(_ manager: TabManager) -> Bool {
        for workspace in manager.tabs {
            for panelID in workspace.panels.keys {
                for terminalPanel in workspace.terminalPanels(projectedFromPanelID: panelID) {
                    if GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func storedRecoverableMainWindowRouteSnapshot(
        for route: RecoverableMainWindowRoute,
        window: NSWindow?
    ) -> MainWindowRouteSnapshot? {
        guard let manager = route.tabManager,
              let sidebar = route.sidebar,
              let sidebarSelection = route.sidebarSelection else {
            return nil
        }
        return MainWindowRouteSnapshot(
            windowId: route.windowId,
            tabManager: manager,
            window: window,
            sidebar: sidebar,
            sidebarSelection: sidebarSelection,
            dock: route.windowDock
        )
    }

    private func recoverableMainWindowRouteSnapshot(
        for route: RecoverableMainWindowRoute
    ) -> MainWindowRouteSnapshot? {
        guard let window = route.window ?? windowForMainWindowId(route.windowId) else { return nil }
        route.window = window
        return storedRecoverableMainWindowRouteSnapshot(for: route, window: window)
    }

    private func recoverableMainWindowPersistenceRouteSnapshot(
        for route: RecoverableMainWindowRoute,
        resolvedWindow: NSWindow?
    ) -> MainWindowPersistenceRouteSnapshot? {
        if let frozenWindowSnapshot = route.frozenWindowSnapshot {
            return .frozen(
                windowId: route.windowId,
                snapshot: frozenWindowSnapshot
            )
        }
        guard let live = storedRecoverableMainWindowRouteSnapshot(
            for: route,
            window: route.window ?? resolvedWindow
        ) else {
            return nil
        }
        return .live(live)
    }

    /// Captures the last live value projection before a recovered window moves
    /// into teardown-only bookkeeping. Closing is rare, so identity lookup is
    /// preferable to relying on an AppKit identifier that may already be gone.
    func recoverableMainWindowRouteSnapshotForClose(
        _ window: NSWindow
    ) -> MainWindowRouteSnapshot? {
        let route = mainWindowId(from: window).flatMap {
            mainWindowLifecycleCoordinator.orphanedRoute(windowId: $0)
        } ?? mainWindowLifecycleCoordinator.orphanedRoutes().first(where: {
            $0.window === window
        })
        guard let route else {
            return nil
        }
        route.window = window
        return storedRecoverableMainWindowRouteSnapshot(for: route, window: window)
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let route = mainWindowLifecycleCoordinator.orphanedRoute(windowId: windowId) else {
            return nil
        }
        return recoverableMainWindowRouteSnapshot(for: route)
    }

    private func recoverableMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        mainWindowLifecycleCoordinator.orphanedRoutes().compactMap { route in
            recoverableMainWindowRouteSnapshot(for: route)
        }
    }

    private func currentMainWindowsByWindowId() -> [UUID: NSWindow] {
        var windowsByWindowId: [UUID: NSWindow] = [:]
        for window in NSApp.windows {
            guard let windowId = mainWindowId(from: window) else { continue }
            windowsByWindowId[windowId] = window
        }
        for context in mainWindowLifecycleCoordinator.registeredContexts {
            if let window = context.window {
                windowsByWindowId[context.windowId] = window
            }
        }
        return windowsByWindowId
    }

    private func currentSurfaceTTYDeviceBindings(
        for route: RecoverableMainWindowRoute
    ) -> [SurfaceResumeBindingIndex.PanelKey: Int64] {
        guard let manager = route.tabManager else { return [:] }
        var bindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]

        func appendBindings(from dock: DockSplitStore) {
            for (panelID, panel) in dock.panels {
                guard let terminal = panel as? TerminalPanel,
                      let device = terminal.surface.controllingTTYDeviceIdentifier,
                      device > 0 else {
                    continue
                }
                bindings[
                    SurfaceResumeBindingIndex.PanelKey(
                        workspaceId: dock.workspaceId,
                        panelId: panelID
                    )
                ] = device
            }
        }

        for workspace in manager.tabs {
            for (panelID, panel) in workspace.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                let device = workspace.surfaceTTYDevices[panelID]
                    ?? terminal.surface.controllingTTYDeviceIdentifier
                guard let device, device > 0 else { continue }
                bindings[
                    SurfaceResumeBindingIndex.PanelKey(
                        workspaceId: workspace.id,
                        panelId: panelID
                    )
                ] = device
            }
            if let dock = workspace._dockSplit {
                appendBindings(from: dock)
            }
        }
        if case .live(let dock)? = route.windowDock {
            appendBindings(from: dock)
        }
        return bindings
    }

    private func availableWindowlessPersistenceSlots() -> Int {
        let eligibleRegisteredCount = mainWindowLifecycleCoordinator.registeredContexts.reduce(
            into: 0
        ) { count, context in
            let route = MainWindowPersistenceRouteSnapshot.live(
                registeredMainWindowRouteSnapshot(for: context)
            )
            if route.isEligibleForSessionPersistence {
                count += 1
            }
        }
        return max(
            0,
            SessionPersistencePolicy.maxWindowsPerSnapshot - eligibleRegisteredCount
        )
    }

    /// Tears down a windowless route that cannot participate in persistence.
    func retireWindowlessRecoverableMainWindowRoute(_ route: RecoverableMainWindowRoute) {
        guard route.window == nil else { return }
        mainWindowLifecycleCoordinator.cancelWindowlessRouteFreezeTask(
            windowId: route.windowId
        )
        if let manager = route.tabManager {
            tearDownWindowlessMainWindowRouteResources(
                windowId: route.windowId,
                manager: manager
            )
        }
        windowConfigFrames.removeValue(forKey: route.windowId)
        route.markForTeardown()
        mainWindowLifecycleCoordinator.removeRecoverableRoute(windowId: route.windowId)
    }

    /// Converts any live orphan whose AppKit window disappeared later into the
    /// same bounded value form used by the production windowless-prune path.
    private func freezeWindowlessRecoverableMainWindowRoutes(
        _ routes: [RecoverableMainWindowRoute],
        windowsByWindowId: [UUID: NSWindow],
        restorableAgentIndex: RestorableAgentSessionIndex?,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> [RecoverableMainWindowRoute] {
        var updatedRoutes: [RecoverableMainWindowRoute] = []
        for route in routes {
            guard route.frozenWindowSnapshot == nil else {
                updatedRoutes.append(route)
                continue
            }
            if let window = route.window ?? windowsByWindowId[route.windowId] {
                route.window = window
                updatedRoutes.append(route)
                continue
            }
            guard let restorableAgentIndex else {
                updatedRoutes.append(route)
                continue
            }
            if let replacement = freezeWindowlessRecoverableMainWindowRoute(
                route,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: surfaceResumeBindingIndex
            ) {
                updatedRoutes.append(replacement)
            }
        }
        return updatedRoutes.filter { route in
            mainWindowLifecycleCoordinator.orphanedRoute(windowId: route.windowId) === route
        }
    }

    /// Freezes one route into a bounded, full-fidelity value snapshot. Lightweight
    /// projections strip scrollback only from the emitted session copy.
    @discardableResult
    private func freezeWindowlessRecoverableMainWindowRoute(
        _ route: RecoverableMainWindowRoute,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> RecoverableMainWindowRoute? {
        guard route.frozenWindowSnapshot == nil else { return route }
        guard route.window == nil,
              windowForMainWindowId(route.windowId) == nil,
              let liveRoute = storedRecoverableMainWindowRouteSnapshot(
                  for: route,
                  window: nil
              ) else {
            return route
        }

        let frozenWindowSnapshot = sessionWindowSnapshot(
            for: liveRoute,
            // Teardown is irreversible. Keep the frozen route at full fidelity;
            // lightweight callers strip scrollback only from their emitted copy.
            includeScrollback: true,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex,
            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable:
                surfaceResumeBindingIndex == nil
        )
        let replacement = RecoverableMainWindowRoute(
            windowId: route.windowId,
            frozenWindowSnapshot: frozenWindowSnapshot
        )
        guard mainWindowLifecycleCoordinator.replaceOrphanedRoute(
            windowId: route.windowId,
            with: replacement
        ) else {
            return nil
        }

        // The frozen value owns the copied frame ring from this point onward.
        windowConfigFrames.removeValue(forKey: route.windowId)
        route.markForTeardown()
        tearDownWindowlessMainWindowRouteResources(
            windowId: route.windowId,
            manager: liveRoute.tabManager
        )
        if frozenWindowSnapshot.omitsRemoteMirrorOnlyWindow(
            liveWorkspaces: liveRoute.tabManager.tabs
        ) {
            mainWindowLifecycleCoordinator.removeRecoverableRoute(
                windowId: route.windowId
            )
            return nil
        }
        return replacement
    }

    /// Starts the cold-cache load without keeping irreversible teardown on the
    /// routing call stack. Identity checks on both sides of the suspension make
    /// a reattached or explicitly closed route win over the deferred freeze.
    private func scheduleWindowlessRecoverableMainWindowRouteFreeze(
        _ route: RecoverableMainWindowRoute
    ) {
        let routeTTYDeviceBindings = currentSurfaceTTYDeviceBindings(for: route)
        let windowId = route.windowId
        let taskToken = UUID()
        let task = Task { @MainActor [weak self, weak route] in
            defer {
                self?.mainWindowLifecycleCoordinator.releaseWindowlessRouteFreezeTask(
                    windowId: windowId,
                    token: taskToken
                )
            }
            guard !Task.isCancelled else { return }
            guard let route,
                  self?.mainWindowLifecycleCoordinator.orphanedRoute(
                      windowId: windowId
                  ) === route,
                  route.window == nil,
                  self?.windowForMainWindowId(windowId) == nil else {
                return
            }
            guard !Task.isCancelled else { return }
            guard self?.mainWindowLifecycleCoordinator.shouldFreezeWindowlessRoute(
                windowId: windowId,
                availablePersistenceSlots: self?.availableWindowlessPersistenceSlots() ?? 0
            ) == true else {
                self?.retireWindowlessRecoverableMainWindowRoute(route)
                return
            }
            defer {
                self?.mainWindowLifecycleCoordinator
                    .cancelWindowlessRecoveryResumeIndexesLoadIfUnused()
            }
            guard let ttyDeviceBindings = self?.mainWindowLifecycleCoordinator
                .windowlessRecoveryTTYDeviceBindings(
                    allBindingsProvider: { [weak self] in
                        self?.currentSurfaceTTYDeviceBindings() ?? [:]
                    },
                    routeBindings: routeTTYDeviceBindings
                ) else {
                return
            }
            let resumeIndexes = await self?.mainWindowLifecycleCoordinator
                .loadWindowlessRecoveryResumeIndexes(
                    ttyDeviceBindings: ttyDeviceBindings
                ) { bindings in
                    await ProcessDetectedResumeIndexes.loadFreshWithDeadline(
                        ttyDeviceBindings: bindings,
                        onWorkerCreated: { [weak self] worker in
                            self?.mainWindowLifecycleCoordinator
                                .retainWindowlessRecoveryResumeIndexesWorker(worker)
                        }
                    )
                }
            guard !Task.isCancelled,
                  self?.mainWindowLifecycleCoordinator.orphanedRoute(
                      windowId: windowId
                  ) === route,
                  route.window == nil,
                  self?.windowForMainWindowId(windowId) == nil else {
                return
            }
            // A timed-out fresh scan must retain the last cached agent projection;
            // only its process-detected surface bindings are unavailable.
            let restorableAgentIndex = resumeIndexes?.restorableAgentIndex
                ?? SharedLiveAgentIndex.shared.index
                ?? .empty
            self?.freezeWindowlessRecoverableMainWindowRoute(
                route,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: resumeIndexes?.surfaceResumeBindingIndex
            )
        }
        mainWindowLifecycleCoordinator.retainWindowlessRouteFreezeTask(
            task,
            windowId: windowId,
            token: taskToken
        )
    }

    /// Clears ephemeral UI state once a window's live graph can no longer return.
    func clearTransientMainWindowState(windowId: UUID, tabManager: TabManager) {
        commandPaletteWindowStore.removeWindow(windowId)
        guard let notificationStore else { return }
        notificationStore.clearNotifications(forTabId: windowId)
        for workspace in tabManager.tabs {
            notificationStore.clearNotifications(forTabId: workspace.id)
        }
    }

    /// Releases processes, browser panels, and remote control clients after a
    /// persistence-only route has captured their complete bounded value state.
    private func tearDownWindowlessMainWindowRouteResources(
        windowId: UUID,
        manager: TabManager
    ) {
        clearTransientMainWindowState(windowId: windowId, tabManager: manager)
        let workspaces = manager.tabs
        remoteTmuxController.handleWindowWorkspacesClosed(
            workspaceIds: workspaces.map(\.id)
        )
        for workspace in workspaces {
            workspace.withClosedPanelHistorySuppressed {
                workspace.teardownAllPanels()
            }
            workspace.teardownRemoteConnection()
            workspace.owningTabManager = nil
        }
        manager.window = nil
    }

    func registeredMainWindowRouteSnapshot(
        for context: MainWindowContext
    ) -> MainWindowRouteSnapshot {
        registeredMainWindowRouteSnapshot(
            for: context,
            resolvedWindow: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    private func registeredMainWindowRouteSnapshot(
        for context: MainWindowContext,
        resolvedWindow: NSWindow?
    ) -> MainWindowRouteSnapshot {
        MainWindowRouteSnapshot(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? resolvedWindow,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            dock: context.existingWindowDock().map { .live($0) }
        )
    }

    private func registeredMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let context = mainWindowLifecycleCoordinator.registeredContext(windowId: windowId) else {
            return nil
        }
        return registeredMainWindowRouteSnapshot(for: context)
    }

    private func registeredMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        mainWindowLifecycleCoordinator.registeredContexts.map {
            registeredMainWindowRouteSnapshot(for: $0)
        }
    }

    /// Resolves one live route without rebuilding, sorting, or validating every
    /// recoverable route. Registered contexts retain precedence.
    func mainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        registeredMainWindowRouteSnapshot(windowId: windowId)
            ?? recoverableMainWindowRouteSnapshot(windowId: windowId)
    }

    /// The authoritative projection for context-independent live routing.
    /// Registered contexts win duplicate window ids; orphaned entries must
    /// still resolve an AppKit window before they can receive live work.
    func mainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        var seenWindowIds: Set<UUID> = []
        var snapshots: [MainWindowRouteSnapshot] = []
        for snapshot in registeredMainWindowRouteSnapshots()
            where seenWindowIds.insert(snapshot.windowId).inserted {
            snapshots.append(snapshot)
        }
        for snapshot in recoverableMainWindowRouteSnapshots()
            where seenWindowIds.insert(snapshot.windowId).inserted {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// The authoritative persistence projection. An orphaned route remains in
    /// this projection even after AppKit has lost the `NSWindow`; only an
    /// explicit close moves it to the non-persisted closing phase.
    ///
    /// This is not always a pure read. Full-scrollback snapshots freeze a bounded
    /// set of windowless orphans into value snapshots, replace their lifecycle
    /// records, tear down their panels, and release their remote connections
    /// before returning. Lightweight fingerprint/autosave projections keep the
    /// live orphan intact. A cold-cache projection also keeps it live until the
    /// asynchronous refresh or snapshot builder supplies a complete index.
    private func mainWindowPersistenceRouteSnapshots(
        restorableAgentIndex suppliedRestorableAgentIndex: RestorableAgentSessionIndex?,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?,
        freezeWindowlessRoutes: Bool
    ) -> [MainWindowPersistenceRouteSnapshot] {
        let windowsByWindowId = currentMainWindowsByWindowId()
        let maximumRecoverableRoutes = availableWindowlessPersistenceSlots()
        if freezeWindowlessRoutes, let suppliedRestorableAgentIndex {
            var candidateOrphanedRoutes: [RecoverableMainWindowRoute] = []
            for route in mainWindowLifecycleCoordinator.orphanedRoutes() {
                guard let snapshot = recoverableMainWindowPersistenceRouteSnapshot(
                    for: route,
                    resolvedWindow: windowsByWindowId[route.windowId]
                ) else {
                    continue
                }
                guard snapshot.isEligibleForSessionPersistence else {
                    retireWindowlessRecoverableMainWindowRoute(route)
                    continue
                }
                guard candidateOrphanedRoutes.count < maximumRecoverableRoutes else {
                    // The persistence cap is an explicit retention boundary. Do not
                    // keep a live panel graph for an orphan that cannot be emitted.
                    retireWindowlessRecoverableMainWindowRoute(route)
                    continue
                }
                candidateOrphanedRoutes.append(route)
            }
            _ = freezeWindowlessRecoverableMainWindowRoutes(
                candidateOrphanedRoutes,
                windowsByWindowId: windowsByWindowId,
                restorableAgentIndex: suppliedRestorableAgentIndex,
                surfaceResumeBindingIndex: surfaceResumeBindingIndex
            )
        }
        let orphanedRoutes = mainWindowLifecycleCoordinator.orphanedRoutes()
            .compactMap { route in
                recoverableMainWindowPersistenceRouteSnapshot(
                    for: route,
                    resolvedWindow: windowsByWindowId[route.windowId]
                )
            }
            .filter(\.isEligibleForSessionPersistence)
            .prefix(maximumRecoverableRoutes)
        var seenWindowIds: Set<UUID> = []
        var snapshots: [MainWindowPersistenceRouteSnapshot] = []
        for context in mainWindowLifecycleCoordinator.registeredContexts {
            let snapshot = registeredMainWindowRouteSnapshot(
                for: context,
                resolvedWindow: windowsByWindowId[context.windowId]
            )
            guard seenWindowIds.insert(snapshot.windowId).inserted else { continue }
            snapshots.append(.live(snapshot))
        }
        for snapshot in orphanedRoutes {
            guard seenWindowIds.insert(snapshot.windowId).inserted else {
                continue
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// Applies one key-window-first ordering to autosave fingerprinting and
    /// bounded session snapshot construction after removing routes that cannot
    /// produce a restorable window.
    func orderedSessionRouteSnapshots(
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil,
        freezeWindowlessRoutes: Bool = true
    ) -> [MainWindowPersistenceRouteSnapshot] {
        mainWindowPersistenceRouteSnapshots(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex,
            freezeWindowlessRoutes: freezeWindowlessRoutes
        )
            .filter(\.isEligibleForSessionPersistence)
            .sorted { lhs, rhs in
                let lhsIsKey = lhs.window?.isKeyWindow ?? false
                let rhsIsKey = rhs.window?.isKeyWindow ?? false
                if lhsIsKey != rhsIsKey {
                    return lhsIsKey && !rhsIsKey
                }
                return lhs.windowId.uuidString < rhs.windowId.uuidString
            }
    }

    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String) {
        let removed = mainWindowLifecycleCoordinator.retireClosingRoutes { route in
            guard let manager = route.tabManager else { return true }
            return !tabManagerHasRegisteredTerminalSurface(manager)
        }
#if DEBUG
        if removed > 0 {
            cmuxDebugLog("recoverableRoute.prune reason=\(reason) removed=\(removed)")
        }
#endif
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        let hadRoute = mainWindowLifecycleCoordinator.teardownRoute(windowId: windowId) != nil
        mainWindowLifecycleCoordinator.removeRecoverableRoute(windowId: windowId)
        if hadRoute {
#if DEBUG
            cmuxDebugLog("recoverableRoute.forget windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
        }
    }

    @discardableResult
    func transitionMainWindowContextToOrphaned(_ context: MainWindowContext) -> Bool {
        let windowId = context.windowId
        let window = context.window ?? windowForMainWindowId(windowId)
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: context.tabManager,
            window: window,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        guard mainWindowLifecycleCoordinator.transitionToOrphaned(route, from: context) else {
            return false
        }
        if window == nil {
            scheduleWindowlessRecoverableMainWindowRouteFreeze(route)
        }
#if DEBUG
        cmuxDebugLog(
            "recoverableRoute.remember windowId=\(String(windowId.uuidString.prefix(8))) " +
                "phase=orphaned"
        )
#endif
        return true
    }

    @discardableResult
    func transitionMainWindowContextToClosing(
        _ context: MainWindowContext,
        window: NSWindow
    ) -> Bool {
        let route = RecoverableMainWindowRoute(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: window,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: false
        )
        return mainWindowLifecycleCoordinator.transitionToClosing(route, from: context)
    }

    @discardableResult
    func transitionRecoverableMainWindowRouteToTeardown(
        windowId: UUID,
        window: NSWindow
    ) -> Bool {
        guard mainWindowLifecycleCoordinator.transitionOrphanedRouteToClosing(
            windowId: windowId,
            window: window
        ) else { return false }
#if DEBUG
        cmuxDebugLog(
            "recoverableRoute.teardown windowId=\(String(windowId.uuidString.prefix(8)))"
        )
#endif
        return true
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        mainWindowLifecycleCoordinator.orphanedRoute(windowId: windowId)
    }

    func recoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        mainWindowLifecycleCoordinator.orphanedRoutes().filter {
            recoverableMainWindowRouteSnapshot(for: $0) != nil
        }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        mainWindowRouteSnapshots().compactMap { snapshot in
            guard let window = snapshot.window else { return nil }
            return MainWindowSummary(
                windowId: snapshot.windowId,
                isKeyWindow: window.isKeyWindow,
                isVisible: window.isVisible,
                workspaceCount: snapshot.tabManager.tabs.count,
                selectedWorkspaceId: snapshot.tabManager.selectedTabId
            )
        }
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        if let context = mainWindowLifecycleCoordinator.registeredContext(windowId: windowId) {
            return context.tabManager
        }
        return recoverableMainWindowRouteSnapshot(windowId: windowId)?.tabManager
    }

    /// Resolves a manager retained only for close bookkeeping. Live routing must
    /// use `tabManagerFor(windowId:)` so teardown-only routes cannot receive work.
    func tabManagerForWindowTeardown(windowId: UUID) -> TabManager? {
        tabManagerFor(windowId: windowId)
            ?? mainWindowLifecycleCoordinator.teardownRoute(windowId: windowId)?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        if let windowId = mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId {
            return windowId
        }
        guard let route = mainWindowLifecycleCoordinator.orphanedRoutes().first(where: {
            $0.tabManager === tabManager
        }), recoverableMainWindowRouteSnapshot(for: route) != nil else {
            return nil
        }
        return route.windowId
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        if let context = contextContainingTabId(workspaceId) {
            return context.window ?? windowForMainWindowId(context.windowId)
        }
        guard let route = mainWindowLifecycleCoordinator.orphanedRoutes().first(where: {
            $0.tabManager?.workspacesById[workspaceId] != nil
        }) else {
            return nil
        }
        return recoverableMainWindowRouteSnapshot(for: route)?.window
    }

    private func scriptableMainWindow(for window: NSWindow) -> ScriptableMainWindowState? {
        if let context = contextForMainTerminalWindow(window, reindex: false) {
            return ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            )
        }

        if let windowId = mainWindowId(from: window),
           let snapshot = recoverableMainWindowRouteSnapshot(windowId: windowId) {
            return ScriptableMainWindowState(
                windowId: snapshot.windowId,
                tabManager: snapshot.tabManager,
                window: snapshot.window
            )
        }

        let windowNumber = window.windowNumber
        guard windowNumber >= 0 else { return nil }
        guard let route = mainWindowLifecycleCoordinator.orphanedRoutes().first(where: { route in
            guard let routeWindow = route.window else { return false }
            return routeWindow === window || routeWindow.windowNumber == windowNumber
        }), let snapshot = recoverableMainWindowRouteSnapshot(for: route),
              let routeWindow = snapshot.window else {
            return nil
        }
        return ScriptableMainWindowState(
            windowId: snapshot.windowId,
            tabManager: snapshot.tabManager,
            window: routeWindow
        )
    }

    func currentScriptableMainWindow() -> ScriptableMainWindowState? {
        var seenWindows = Set<ObjectIdentifier>()

        func resolve(_ window: NSWindow?) -> ScriptableMainWindowState? {
            guard let window else { return nil }
            guard seenWindows.insert(ObjectIdentifier(window)).inserted else { return nil }
            return scriptableMainWindow(for: window)
        }

        if let state = resolve(NSApp.keyWindow) {
            return state
        }
        if let state = resolve(NSApp.mainWindow) {
            return state
        }
        for window in NSApp.orderedWindows {
            if let state = resolve(window) {
                return state
            }
        }
        return scriptableMainWindows().first
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        var results: [ScriptableMainWindowState] = []
        var seen: Set<UUID> = []

        for window in NSApp.orderedWindows {
            guard let state = scriptableMainWindow(for: window) else { continue }
            guard seen.insert(state.windowId).inserted else { continue }
            results.append(state)
        }

        let remaining = mainWindowRouteSnapshots()
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { snapshot in
                snapshot.window != nil && seen.insert(snapshot.windowId).inserted
            }

        for snapshot in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        guard let snapshot = mainWindowRouteSnapshot(windowId: windowId),
              let window = snapshot.window else { return nil }
        return ScriptableMainWindowState(
            windowId: snapshot.windowId,
            tabManager: snapshot.tabManager,
            window: window
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        if let context = contextContainingTabId(tabId),
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            return ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
        guard let route = mainWindowLifecycleCoordinator.orphanedRoutes().first(where: {
            $0.tabManager?.workspacesById[tabId] != nil
        }), let snapshot = recoverableMainWindowRouteSnapshot(for: route),
              let window = snapshot.window else {
            return nil
        }
        return ScriptableMainWindowState(
            windowId: snapshot.windowId,
            tabManager: snapshot.tabManager,
            window: window
        )
    }

    func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.workspacesById[tabId] != nil {
                return context
            }
        }
        return nil
    }

    /// One-pass `tabId -> workspace title` index across every window context.
    /// Callers can limit the projection to the workspace ids they render, keeping
    /// notification lists O(tabs + groups) rather than O(notifications × tabs).
    /// Registered/recoverable window routes win, then the active `tabManager`
    /// fills any missing ids.
    /// See https://github.com/manaflow-ai/cmux/issues/5794.
    func tabTitlesByTabId(for requestedTabIds: Set<UUID>? = nil) -> [UUID: String] {
        var titles: [UUID: String] = [:]

        func appendTitles(from manager: TabManager) {
            let candidateIds = requestedTabIds ?? Set(manager.tabs.map(\.id))
            let unresolvedIds = candidateIds.subtracting(titles.keys)
            titles.merge(manager.resolvedWorkspaceDisplayTitles(for: unresolvedIds)) { current, _ in current }
        }

        for snapshot in mainWindowRouteSnapshots() {
            appendTitles(from: snapshot.tabManager)
            if let requestedTabIds, titles.count == requestedTabIds.count { return titles }
        }
        if let remainingTitleSource = tabManager {
            appendTitles(from: remainingTitleSource)
        }
        return titles
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        if let context = contextContainingTabId(tabId) {
            return context.tabManager
        }
        if let route = mainWindowLifecycleCoordinator.orphanedRoutes().first(where: {
            $0.tabManager?.workspacesById[tabId] != nil
        }), let manager = recoverableMainWindowRouteSnapshot(for: route)?.tabManager {
            return manager
        }
        guard let tabManager, tabManager.workspacesById[tabId] != nil else {
            return nil
        }
        return tabManager
    }
}
