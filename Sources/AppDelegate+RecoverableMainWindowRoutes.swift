import AppKit
import ObjectiveC.runtime

@MainActor
final class RecoverableMainWindowRoute {
    let windowId: UUID
    weak var tabManager: TabManager?
    weak var window: NSWindow?
    let order: UInt64

    init(windowId: UUID, tabManager: TabManager, window: NSWindow?, order: UInt64) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.window = window
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

private var mainWindowRouteLedgerKey: UInt8 = 0

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
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if TerminalSurfaceRegistry.shared.surface(id: terminalPanel.id) === terminalPanel.surface {
                    return true
                }
            }
        }
        return false
    }

    private func liveRecoverableMainWindow(windowId: UUID, cachedWindow: NSWindow?) -> NSWindow? {
        cachedWindow ?? windowForMainWindowId(windowId)
    }

    private func sortedRecoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        mainWindowRouteLedger.routesByWindowId.values.sorted { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order > rhs.order
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let route = mainWindowRouteLedger.routesByWindowId[windowId],
              let manager = route.tabManager,
              let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else {
            return nil
        }
        return MainWindowRouteSnapshot(windowId: route.windowId, tabManager: manager, window: window)
    }

    private func recoverableMainWindowRouteSnapshots() -> [MainWindowRouteSnapshot] {
        sortedRecoverableMainWindowRoutes().compactMap { route in
            guard let manager = route.tabManager,
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

    func rememberRecoverableMainWindowRoute(windowId: UUID, tabManager: TabManager, window: NSWindow?) {
        guard let window = liveRecoverableMainWindow(windowId: windowId, cachedWindow: window) else { return }
        guard tabManagerHasRegisteredTerminalSurface(tabManager) else { return }
        mainWindowRouteLedger.routesByWindowId[windowId] = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: tabManager,
            window: window,
            order: mainWindowRouteLedger.issueOrder()
        )
#if DEBUG
        cmuxDebugLog("recoverableRoute.remember windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard recoverableMainWindowRouteSnapshot(windowId: windowId) != nil else { return nil }
        return mainWindowRouteLedger.routesByWindowId[windowId]
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
        return recoverableMainWindowRouteSnapshot(windowId: windowId)?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        if let windowId = mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId {
            return windowId
        }
        return recoverableMainWindowRouteSnapshots().first(where: { $0.tabManager === tabManager })?.windowId
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
