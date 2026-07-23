import AppKit
import CmuxTerminalCore
import ObjectiveC.runtime

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    weak var tabManager: TabManager?
    weak var window: NSWindow?
    let sidebarSnapshot: SessionSidebarSnapshot
    let order: UInt64

    init(
        windowId: UUID,
        tabManager: TabManager,
        window: NSWindow?,
        sidebarSnapshot: SessionSidebarSnapshot,
        order: UInt64
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.window = window
        self.sidebarSnapshot = sidebarSnapshot
        self.order = order
    }
}

@MainActor
private final class MainWindowRouteLedger {
    var routesByWindowId: [UUID: RecoverableMainWindowRoute] = [:]
    private var nextOrder: UInt64 = 0

    func issueOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }
}

@MainActor
private struct MainWindowRouteSnapshot {
    let windowId: UUID
    let tabManager: TabManager
    let window: NSWindow?
}

typealias MainWindowSessionPersistenceRoute = (windowId: UUID, tabManager: TabManager, window: NSWindow?, sidebarSnapshot: SessionSidebarSnapshot)
private var mainWindowRouteLedgerKey: UInt8 = 0

// The retire sweep is the MainWindowRouteRetiring witness: terminal topology
// changes prompt a coalesced lifecycle audit through the seam instead of the
// registry reaching up to AppDelegate.shared.
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

    private func tabManagerCanOwnRecoverableMainWindowRoute(_ manager: TabManager) -> Bool {
        !manager.isFinalizedForWindowClose
    }

    func liveRecoverableMainWindow(windowId: UUID, cachedWindow: NSWindow?) -> NSWindow? {
        let appKitWindows = NSApp.windows
        guard let cachedWindow,
              appKitWindows.contains(where: { $0 === cachedWindow }),
              cachedWindow.isVisible || cachedWindow.isMiniaturized,
              mainWindowId(from: cachedWindow) == windowId else {
            return nil
        }
        return cachedWindow
    }

    private func sortedRecoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        pruneInactiveRecoverableMainWindowRoutes(reason: "collection")
        return mainWindowRouteLedger.routesByWindowId.values.sorted { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order > rhs.order
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func pruneInactiveRecoverableMainWindowRoutes(reason: String) {
        guard mainWindowRouteLedger.routesByWindowId.values.contains(where: { route in
            guard let manager = route.tabManager else { return true }
            return !tabManagerCanOwnRecoverableMainWindowRoute(manager)
        }) else { return }

        let before = mainWindowRouteLedger.routesByWindowId.count
        mainWindowRouteLedger.routesByWindowId = mainWindowRouteLedger.routesByWindowId.filter { _, route in
            guard let manager = route.tabManager else { return false }
            return tabManagerCanOwnRecoverableMainWindowRoute(manager)
        }
        let after = mainWindowRouteLedger.routesByWindowId.count
#if DEBUG
        if after != before {
            cmuxDebugLog("recoverableRoute.prune reason=\(reason) removed=\(before - after) remaining=\(after)")
        }
#endif
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        pruneInactiveRecoverableMainWindowRoutes(reason: "snapshotAccess")
        guard let route = mainWindowRouteLedger.routesByWindowId[windowId],
              let manager = route.tabManager,
              tabManagerCanOwnRecoverableMainWindowRoute(manager),
              let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else {
            return nil
        }
        return MainWindowRouteSnapshot(windowId: route.windowId, tabManager: manager, window: window)
    }

    private func recoverableMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        sortedRecoverableMainWindowRoutes().compactMap { route in
            guard let manager = route.tabManager,
                  tabManagerCanOwnRecoverableMainWindowRoute(manager),
                  let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else {
                return nil
            }
            return MainWindowRouteSnapshot(windowId: route.windowId, tabManager: manager, window: window)
        }
    }

    private func liveRegisteredMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        mainWindowContexts.values.compactMap { context in
            guard let window = context.window ?? windowForMainWindowId(context.windowId) else { return nil }
            return MainWindowRouteSnapshot(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
    }

    /// Persistence includes windowless recoverable owners; registered contexts win overlaps.
    func mainWindowSessionPersistenceRoutes() -> [MainWindowSessionPersistenceRoute] {
        var seenWindowIds: Set<UUID> = []
        var seenTabManagers: Set<ObjectIdentifier> = []
        var routes: [MainWindowSessionPersistenceRoute] = []

        for context in mainWindowContexts.values {
            let managerId = ObjectIdentifier(context.tabManager)
            guard !seenWindowIds.contains(context.windowId),
                  !seenTabManagers.contains(managerId) else {
                continue
            }
            seenWindowIds.insert(context.windowId)
            seenTabManagers.insert(managerId)
            routes.append(
                (
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId),
                    sidebarSnapshot: sessionSidebarSnapshot(for: context)
                )
            )
        }

        for route in sortedRecoverableMainWindowRoutes() {
            guard let manager = route.tabManager,
                  tabManagerCanOwnRecoverableMainWindowRoute(manager) else {
                continue
            }
            let managerId = ObjectIdentifier(manager)
            guard !seenWindowIds.contains(route.windowId),
                  !seenTabManagers.contains(managerId) else {
                continue
            }
            seenWindowIds.insert(route.windowId)
            seenTabManagers.insert(managerId)
            routes.append(
                (
                    windowId: route.windowId,
                    tabManager: manager,
                    window: route.window,
                    sidebarSnapshot: route.sidebarSnapshot
                )
            )
        }

        return routes
    }

    func retireInactiveRecoverableMainWindowRoutes(reason: String) {
        pruneInactiveRecoverableMainWindowRoutes(reason: reason)
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        if mainWindowRouteLedger.routesByWindowId.removeValue(forKey: windowId) != nil {
#if DEBUG
            cmuxDebugLog("recoverableRoute.forget windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
        }
    }

    func rememberRecoverableMainWindowRoute(
        windowId: UUID,
        tabManager: TabManager,
        window: NSWindow?,
        sidebarSnapshot: SessionSidebarSnapshot
    ) {
        pruneInactiveRecoverableMainWindowRoutes(reason: "insertion")
        guard tabManagerCanOwnRecoverableMainWindowRoute(tabManager) else { return }
        mainWindowRouteLedger.routesByWindowId[windowId] = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: tabManager,
            window: window,
            sidebarSnapshot: sidebarSnapshot,
            order: mainWindowRouteLedger.issueOrder()
        )
#if DEBUG
        cmuxDebugLog("recoverableRoute.remember windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        // Keep the weak manager route alive while SwiftUI/AppKit replaces its
        // NSWindow. Snapshot-based listing/focus APIs still require a live
        // window, so this internal route cannot surface a ghost window.
        pruneInactiveRecoverableMainWindowRoutes(reason: "routeAccess")
        guard let route = mainWindowRouteLedger.routesByWindowId[windowId],
              let manager = route.tabManager,
              tabManagerCanOwnRecoverableMainWindowRoute(manager) else { return nil }
        return route
    }

    func recoverableMainWindowTabManager(forExactWindow window: NSWindow) -> TabManager? {
        sortedRecoverableMainWindowRoutes().first { route in
            guard route.window === window, let manager = route.tabManager else { return false }
            return tabManagerCanOwnRecoverableMainWindowRoute(manager)
        }?.tabManager
    }

    func ownsMainWindowTabManager(_ tabManager: TabManager) -> Bool {
        if mainWindowContexts.values.contains(where: { $0.tabManager === tabManager }) {
            return true
        }
        return sortedRecoverableMainWindowRoutes().contains { route in
            route.tabManager === tabManager
                && tabManagerCanOwnRecoverableMainWindowRoute(tabManager)
        }
    }

    func recoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        let validWindowIds = Set(recoverableMainWindowRouteSnapshots().map(\.windowId))
        return sortedRecoverableMainWindowRoutes().filter { validWindowIds.contains($0.windowId) }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        var seen: Set<UUID> = []
        var summaries = liveRegisteredMainWindowRouteSnapshots().map { snapshot in
            seen.insert(snapshot.windowId)
            return MainWindowSummary(
                windowId: snapshot.windowId,
                isKeyWindow: snapshot.window?.isKeyWindow ?? false,
                isVisible: snapshot.window?.isVisible ?? false,
                workspaceCount: snapshot.tabManager.tabs.count,
                selectedWorkspaceId: snapshot.tabManager.selectedTabId
            )
        }
        for snapshot in recoverableMainWindowRouteSnapshots() where seen.insert(snapshot.windowId).inserted {
            summaries.append(
                MainWindowSummary(
                    windowId: snapshot.windowId,
                    isKeyWindow: snapshot.window?.isKeyWindow ?? false,
                    isVisible: snapshot.window?.isVisible ?? false,
                    workspaceCount: snapshot.tabManager.tabs.count,
                    selectedWorkspaceId: snapshot.tabManager.selectedTabId
                )
            )
        }
        return summaries
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        if let snapshot = liveRegisteredMainWindowRouteSnapshots().first(where: { $0.windowId == windowId }) {
            return snapshot.tabManager
        }
        // A registered context remains the windowId→manager authority even
        // when its NSWindow is gone (mid-teardown) or absent (windowless test
        // contexts); otherwise window-scoped routing silently falls back to
        // another window's manager.
        if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            return context.tabManager
        }
        // The raw ledger preserves lifecycle state while AppKit swaps windows.
        // Only its live, exact-window snapshot is mutation-routing authority.
        return recoverableMainWindowRouteSnapshot(windowId: windowId)?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        if let windowId = mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId {
            return windowId
        }
        guard tabManagerCanOwnRecoverableMainWindowRoute(tabManager) else { return nil }
        return sortedRecoverableMainWindowRoutes()
            .first(where: { $0.tabManager === tabManager })?
            .windowId
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        for context in mainWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                return window
            }
        }
        for snapshot in recoverableMainWindowRouteSnapshots() {
            guard snapshot.tabManager.tabs.contains(where: { $0.id == workspaceId }) else {
                continue
            }
            return snapshot.window
        }
        return nil
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
        for snapshot in recoverableMainWindowRouteSnapshots() {
            guard let routeWindow = snapshot.window,
                  routeWindow === window || routeWindow.windowNumber == windowNumber else {
                continue
            }
            return ScriptableMainWindowState(
                windowId: snapshot.windowId,
                tabManager: snapshot.tabManager,
                window: routeWindow
            )
        }
        return nil
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

        let remaining = liveRegisteredMainWindowRouteSnapshots()
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { seen.insert($0.windowId).inserted }

        for snapshot in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        for snapshot in recoverableMainWindowRouteSnapshots() where seen.insert(snapshot.windowId).inserted {
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
        if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            return ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
        guard let snapshot = recoverableMainWindowRouteSnapshot(windowId: windowId) else { return nil }
        return ScriptableMainWindowState(
            windowId: snapshot.windowId,
            tabManager: snapshot.tabManager,
            window: snapshot.window
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        if let context = contextContainingTabId(tabId) {
            guard let window = context.window ?? windowForMainWindowId(context.windowId) else { return nil }
            return ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
        for snapshot in recoverableMainWindowRouteSnapshots() {
            guard snapshot.tabManager.tabs.contains(where: { $0.id == tabId }) else {
                continue
            }
            return ScriptableMainWindowState(
                windowId: snapshot.windowId,
                tabManager: snapshot.tabManager,
                window: snapshot.window
            )
        }
        return nil
    }

    func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    /// One-pass `tabId -> workspace title` index across every window context.
    /// Callers can limit the projection to the workspace ids they render, keeping
    /// notification lists O(tabs + groups) rather than O(notifications × tabs).
    /// Window contexts win, then the active `tabManager` fills any missing ids.
    /// See https://github.com/manaflow-ai/cmux/issues/5794.
    func tabTitlesByTabId(for requestedTabIds: Set<UUID>? = nil) -> [UUID: String] {
        var titles: [UUID: String] = [:]

        func appendTitles(from manager: TabManager) {
            let candidateIds = requestedTabIds ?? Set(manager.tabs.map(\.id))
            let unresolvedIds = candidateIds.subtracting(titles.keys)
            titles.merge(manager.resolvedWorkspaceDisplayTitles(for: unresolvedIds)) { current, _ in current }
        }

        for context in mainWindowContexts.values {
            appendTitles(from: context.tabManager)
            if let requestedTabIds, titles.count == requestedTabIds.count { return titles }
        }
        if let remainingTitleSource = tabManager {
            appendTitles(from: remainingTitleSource)
        }
        return titles
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        if let manager = contextContainingTabId(tabId)?.tabManager {
            return manager
        }
        return recoverableMainWindowRoutes()
            .compactMap(\.tabManager)
            .first { manager in
                manager.tabs.contains(where: { $0.id == tabId })
            }
    }
}
