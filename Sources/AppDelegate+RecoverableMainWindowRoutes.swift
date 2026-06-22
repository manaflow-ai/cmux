import AppKit
import CmuxTerminalCore
import CmuxTerminal
import CmuxWindowing

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
private struct MainWindowRouteSnapshot {
    let windowId: UUID
    let tabManager: TabManager
    let window: NSWindow?
}

// The retire sweep is the MainWindowRouteRetiring witness: the terminal
// surface registry (CmuxTerminalEngine) calls it through the seam instead of
// reaching up to AppDelegate.shared.
extension AppDelegate: MainWindowRouteRetiring {}

extension AppDelegate {
    private func tabManagerHasRegisteredTerminalSurface(_ manager: TabManager) -> Bool {
        for workspace in manager.tabs {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface {
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
        recoverableMainWindowRouteLedger.sortedByMostRecentFirst()
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let route = recoverableMainWindowRouteLedger.route(for: WindowID(windowId)),
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
        registeredMainWindows.compactMap { context in
            guard let window = context.window ?? windowForMainWindowId(context.windowId) else { return nil }
            return MainWindowRouteSnapshot(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
    }

    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String) {
        let before = recoverableMainWindowRouteLedger.count
        recoverableMainWindowRouteLedger.retainRoutes { _, route in
            guard let manager = route.tabManager else { return false }
            guard let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else { return false }
            route.window = window
            return tabManagerHasRegisteredTerminalSurface(manager)
        }
        let after = recoverableMainWindowRouteLedger.count
#if DEBUG
        if after != before {
            cmuxDebugLog("recoverableRoute.prune reason=\(reason) removed=\(before - after) remaining=\(after)")
        }
#endif
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        if recoverableMainWindowRouteLedger.remove(WindowID(windowId)) != nil {
#if DEBUG
            cmuxDebugLog("recoverableRoute.forget windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
        }
    }

    func rememberRecoverableMainWindowRoute(windowId: UUID, tabManager: TabManager, window: NSWindow?) {
        guard let window = liveRecoverableMainWindow(windowId: windowId, cachedWindow: window) else { return }
        guard tabManagerHasRegisteredTerminalSurface(tabManager) else { return }
        let order = recoverableMainWindowRouteLedger.issueOrder()
        recoverableMainWindowRouteLedger.setRoute(
            RecoverableMainWindowRoute(
                windowId: windowId,
                tabManager: tabManager,
                window: window,
                order: order
            ),
            order: order,
            for: WindowID(windowId)
        )
#if DEBUG
        cmuxDebugLog("recoverableRoute.remember windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard recoverableMainWindowRouteSnapshot(windowId: windowId) != nil else { return nil }
        return recoverableMainWindowRouteLedger.route(for: WindowID(windowId))
    }

    func recoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        let validWindowIds = Set(recoverableMainWindowRouteSnapshots().map(\.windowId))
        return sortedRecoverableMainWindowRoutes().filter { validWindowIds.contains($0.windowId) }
    }

    private func mainWindowSummary(from snapshot: MainWindowRouteSnapshot) -> MainWindowSummary {
        MainWindowSummary(
            windowId: snapshot.windowId,
            isKeyWindow: snapshot.window?.isKeyWindow ?? false,
            isVisible: snapshot.window?.isVisible ?? false,
            workspaceCount: snapshot.tabManager.tabs.count,
            selectedWorkspaceId: snapshot.tabManager.selectedTabId
        )
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        var seen: Set<WindowID> = []
        var summaries: [MainWindowSummary] = []
        for snapshot in liveRegisteredMainWindowRouteSnapshots() {
            seen.insert(WindowID(snapshot.windowId))
            summaries.append(mainWindowSummary(from: snapshot))
        }
        recoverableMainWindowRouteLedger.appendingDeduplicatedProjections(into: &summaries, seen: &seen) { route in
            guard let snapshot = recoverableMainWindowRouteSnapshot(windowId: route.windowId) else { return nil }
            return (id: WindowID(snapshot.windowId), projection: mainWindowSummary(from: snapshot))
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
        if let windowId = registeredMainWindow(forManager: tabManager)?.windowId {
            return windowId
        }
        return recoverableMainWindowRouteSnapshots().first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        for context in registeredMainWindows where context.tabManager.tabs.contains(where: { $0.id == workspaceId }) {
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

    private func makeOrderedMainWindowResolver() -> OrderedMainWindowResolver {
        OrderedMainWindowResolver(
            keyWindow: { NSApp.keyWindow },
            mainWindow: { NSApp.mainWindow },
            orderedWindows: { NSApp.orderedWindows }
        )
    }

    func currentScriptableMainWindow() -> ScriptableMainWindowState? {
        makeOrderedMainWindowResolver().resolve(
            project: { scriptableMainWindow(for: $0) },
            fallback: { scriptableMainWindows().first }
        )
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        var results: [ScriptableMainWindowState] = []
        var seen: Set<WindowID> = []

        for window in NSApp.orderedWindows {
            guard let state = scriptableMainWindow(for: window) else { continue }
            guard seen.insert(WindowID(state.windowId)).inserted else { continue }
            results.append(state)
        }

        let remaining = liveRegisteredMainWindowRouteSnapshots()
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { seen.insert(WindowID($0.windowId)).inserted }

        for snapshot in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        recoverableMainWindowRouteLedger.appendingDeduplicatedProjections(into: &results, seen: &seen) { route in
            guard let snapshot = recoverableMainWindowRouteSnapshot(windowId: route.windowId) else { return nil }
            return (
                id: WindowID(snapshot.windowId),
                projection: ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        if let context = registeredMainWindow(forWindowId: windowId),
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

    func contextContainingTabId(_ tabId: UUID) -> RegisteredMainWindow? {
        for context in registeredMainWindows {
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
