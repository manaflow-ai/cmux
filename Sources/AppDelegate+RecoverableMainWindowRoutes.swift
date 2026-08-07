import AppKit
import CmuxTerminalCore
import CmuxTerminal
import ObjectiveC.runtime

@MainActor
private final class MainWindowRouteLedger {
    var routesByWindowId: [UUID: RecoverableMainWindowRoute] = [:]
    private var nextOrder: UInt64 = 0

    func issueOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }
}

private var mainWindowRouteLedgerKey: UInt8 = 0

// The retire sweep is the MainWindowRouteRetiring witness: the terminal
// surface registry (CmuxTerminalEngine) calls it through the seam instead of
// reaching up to AppDelegate.shared.
extension AppDelegate: MainWindowRouteRetiring {}

extension AppDelegate {
    private var mainWindowRouteLedger: MainWindowRouteLedger {
        if let ledger = objc_getAssociatedObject(self, &mainWindowRouteLedgerKey) as? MainWindowRouteLedger {
            return ledger
        }
        let ledger = MainWindowRouteLedger()
        objc_setAssociatedObject(self, &mainWindowRouteLedgerKey, ledger, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return ledger
    }

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

    private func liveRecoverableMainWindow(windowId: UUID, cachedWindow: NSWindow?) -> NSWindow? {
        cachedWindow ?? windowForMainWindowId(windowId)
    }

    private func recoverableWindowParticipatesInLiveTopology(
        _ window: NSWindow,
        purpose: RecoverableMainWindowRoutePurpose
    ) -> Bool {
        guard purpose == .liveRecovery else { return false }
        return window.isVisible
            || window.isMiniaturized
            || mainWindowParticipatedBeforeApplicationHide(window)
    }

    private func sortedRecoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        mainWindowRouteLedger.routesByWindowId.values.sorted { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order > rhs.order
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func recoverableMainWindowRouteSnapshot(
        for route: RecoverableMainWindowRoute
    ) -> MainWindowRouteSnapshot? {
        guard let manager = route.tabManager,
              tabManagerHasRegisteredTerminalSurface(manager),
              let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window),
              recoverableWindowParticipatesInLiveTopology(window, purpose: route.purpose) else {
            return nil
        }
        return MainWindowRouteSnapshot(
            windowId: route.windowId,
            tabManager: manager,
            window: window,
            sidebar: route.sidebar,
            sidebarSelection: route.sidebarSelection,
            dock: route.frozenWindowDockSnapshot.map { .frozen($0) }
        )
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let route = mainWindowRouteLedger.routesByWindowId[windowId] else { return nil }
        return recoverableMainWindowRouteSnapshot(for: route)
    }

    private func recoverableMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        sortedRecoverableMainWindowRoutes().compactMap { route in
            recoverableMainWindowRouteSnapshot(for: route)
        }
    }

    func registeredMainWindowRouteSnapshot(
        for context: MainWindowContext
    ) -> MainWindowRouteSnapshot {
        MainWindowRouteSnapshot(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId),
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            dock: context.existingWindowDock().map { .live($0) }
        )
    }

    private func registeredMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        return registeredMainWindowRouteSnapshot(for: context)
    }

    private func registeredMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        mainWindowContexts.values.map { registeredMainWindowRouteSnapshot(for: $0) }
    }

    /// Resolves one live route without rebuilding, sorting, or validating every
    /// recoverable route. Registered contexts retain precedence.
    func mainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        registeredMainWindowRouteSnapshot(windowId: windowId)
            ?? recoverableMainWindowRouteSnapshot(windowId: windowId)
    }

    /// The authoritative projection for context-independent window routing and
    /// persistence. Registered contexts win duplicate window ids; recoverable
    /// entries must still own a live terminal surface before they participate.
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

    /// Applies the same key-window-first ordering to autosave fingerprinting
    /// and snapshot truncation so both select the same bounded route set.
    func orderedSessionRouteSnapshots() -> [MainWindowRouteSnapshot] {
        mainWindowRouteSnapshots().sorted { lhs, rhs in
            let lhsIsKey = lhs.window?.isKeyWindow ?? false
            let rhsIsKey = rhs.window?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String) {
        let before = mainWindowRouteLedger.routesByWindowId.count
        mainWindowRouteLedger.routesByWindowId = mainWindowRouteLedger.routesByWindowId.filter { _, route in
            guard let manager = route.tabManager else { return false }
            guard let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else { return false }
            route.window = window
            return tabManagerHasRegisteredTerminalSurface(manager)
        }
        let after = mainWindowRouteLedger.routesByWindowId.count
#if DEBUG
        if after != before {
            cmuxDebugLog("recoverableRoute.prune reason=\(reason) removed=\(before - after) remaining=\(after)")
        }
#endif
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        if mainWindowRouteLedger.routesByWindowId.removeValue(forKey: windowId) != nil {
#if DEBUG
            cmuxDebugLog("recoverableRoute.forget windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
        }
    }

    func rememberRecoverableMainWindowRoute(
        _ context: MainWindowContext,
        purpose: RecoverableMainWindowRoutePurpose
    ) {
        let windowId = context.windowId
        let window = context.window
        guard let window = liveRecoverableMainWindow(windowId: windowId, cachedWindow: window) else { return }
        guard tabManagerHasRegisteredTerminalSurface(context.tabManager) else { return }
        let frozenWindowDockSnapshot: SessionSplitContainerSnapshot? = purpose == .liveRecovery
            ? context.windowDockSessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh(),
                surfaceResumeBindingIndex: nil
            )
            : nil
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: context.tabManager,
            window: window,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            frozenWindowDockSnapshot: frozenWindowDockSnapshot,
            purpose: purpose,
            order: mainWindowRouteLedger.issueOrder()
        )
        if purpose == .liveRecovery {
            route.closeObserver = WindowCloseObserver(window: window) { [weak self] closingWindow in
                self?.markRecoverableMainWindowRouteForTeardown(
                    windowId: windowId,
                    window: closingWindow
                )
            }
        }
        mainWindowRouteLedger.routesByWindowId[windowId] = route
#if DEBUG
        cmuxDebugLog(
            "recoverableRoute.remember windowId=\(String(windowId.uuidString.prefix(8))) " +
                "purpose=\(purpose.rawValue)"
        )
#endif
    }

    private func markRecoverableMainWindowRouteForTeardown(
        windowId: UUID,
        window: NSWindow
    ) {
        guard let route = mainWindowRouteLedger.routesByWindowId[windowId] else { return }
        route.markForTeardown()
        discardClosedRecoverableMainWindowVisibilityState(window)
#if DEBUG
        cmuxDebugLog(
            "recoverableRoute.teardown windowId=\(String(windowId.uuidString.prefix(8)))"
        )
#endif
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard recoverableMainWindowRouteSnapshot(windowId: windowId) != nil else { return nil }
        return mainWindowRouteLedger.routesByWindowId[windowId]
    }

    func recoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        sortedRecoverableMainWindowRoutes().filter {
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
        if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            return context.tabManager
        }
        return recoverableMainWindowRouteSnapshot(windowId: windowId)?.tabManager
    }

    /// Resolves a manager retained only for close bookkeeping. Live routing must
    /// use `tabManagerFor(windowId:)` so teardown-only routes cannot receive work.
    func tabManagerForWindowTeardown(windowId: UUID) -> TabManager? {
        tabManagerFor(windowId: windowId)
            ?? mainWindowRouteLedger.routesByWindowId[windowId]?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        if let windowId = mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId {
            return windowId
        }
        guard let route = mainWindowRouteLedger.routesByWindowId.values.first(where: {
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
        guard let route = mainWindowRouteLedger.routesByWindowId.values.first(where: {
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
        guard let route = mainWindowRouteLedger.routesByWindowId.values.first(where: { route in
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
        guard let route = mainWindowRouteLedger.routesByWindowId.values.first(where: {
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
        if let route = mainWindowRouteLedger.routesByWindowId.values.first(where: {
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
