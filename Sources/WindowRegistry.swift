import AppKit
import Bonsplit
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
struct WindowRegistryHostSeams {
    let registeredMainWindows: @MainActor () -> [AppDelegate.RegisteredMainWindow]
    let registeredMainWindowForManager: @MainActor (TabManager) -> AppDelegate.RegisteredMainWindow?
    let registeredMainWindowForWindowId: @MainActor (UUID) -> AppDelegate.RegisteredMainWindow?
    let contextForMainTerminalWindow: @MainActor (NSWindow, Bool) -> AppDelegate.RegisteredMainWindow?
    let mainWindowIdFromWindow: @MainActor (NSWindow) -> UUID?
    let windowForMainWindowId: @MainActor (UUID) -> NSWindow?

    init(
        registeredMainWindows: @escaping @MainActor () -> [AppDelegate.RegisteredMainWindow] = { [] },
        registeredMainWindowForManager: @escaping @MainActor (TabManager) -> AppDelegate.RegisteredMainWindow? = { _ in nil },
        registeredMainWindowForWindowId: @escaping @MainActor (UUID) -> AppDelegate.RegisteredMainWindow? = { _ in nil },
        contextForMainTerminalWindow: @escaping @MainActor (NSWindow, Bool) -> AppDelegate.RegisteredMainWindow? = { _, _ in nil },
        mainWindowIdFromWindow: @escaping @MainActor (NSWindow) -> UUID? = { _ in nil },
        windowForMainWindowId: @escaping @MainActor (UUID) -> NSWindow? = { _ in nil }
    ) {
        self.registeredMainWindows = registeredMainWindows
        self.registeredMainWindowForManager = registeredMainWindowForManager
        self.registeredMainWindowForWindowId = registeredMainWindowForWindowId
        self.contextForMainTerminalWindow = contextForMainTerminalWindow
        self.mainWindowIdFromWindow = mainWindowIdFromWindow
        self.windowForMainWindowId = windowForMainWindowId
    }
}

@MainActor
private struct MainWindowRouteSnapshot {
    let windowId: UUID
    let tabManager: TabManager
    let window: NSWindow?
}

/// Cross-window index of per-window ``WindowContext``s, keyed by ``WindowID``.
///
/// This replaces the six parallel `WindowScopedStore<…>` dictionaries
/// `AppDelegate` used to hold (`windowTabManagers`, `windowFocusControllers`,
/// `windowConfigStores`, `windowSidebarSelectionStates`, `windowSidebarStates`,
/// `windowFileExplorerStates`). The per-window state now lives in one
/// ``WindowContext`` per `NSWindow`; this registry is the single
/// `WindowID`→context index and recoverable-route owner the window-lifecycle seam
/// (`resolveRegisteredWindow`, `seedNewMainWindowSlices`,
/// `rebindRegisteredWindowSlices`, `removeWindowModelSlices`, …) and the
/// per-window config/sidebar/file-explorer accessors resolve through.
///
/// The cross-window resolver family (`tabManagerFor`, `locateSurface`,
/// `scriptableMainWindow`, …) lives here and is reached through AppDelegate
/// forwarders during the migration. Host lookups that still belong to
/// AppDelegate/window lifecycle are injected through ``WindowRegistryHostSeams``;
/// the resolver order remains live registered windows first, then the
/// recoverable-route ledger.
///
/// ## Ownership + teardown
///
/// The registry is the single strong owner of each ``WindowContext`` (exactly
/// replacing the dictionaries' strong ownership), so a context's lifetime
/// matches the old per-slice dictionary entries. It is a passive index: it does
/// NOT subscribe to `windowCoordinator.windowClosed` (a single-consumer stream
/// whose sole consumer is the window-teardown loop). Slice removal is driven by
/// that loop's single `removeWindowModelSlices` funnel calling
/// ``removeContext(for:)``.
///
/// ## Isolation
///
/// `@MainActor` because its mutators run on the main thread alongside window
/// registration and AppKit teardown. Internally it reuses the package's
/// ``WindowScopedStore`` (the canonical `WindowID`-keyed per-window store) as
/// its backing dictionary.
@MainActor
final class WindowRegistry {
    private let store = WindowScopedStore<WindowContext>()
    private var hostSeams = WindowRegistryHostSeams()

    /// Ordered ledger of recoverable main-window routes remembered during window
    /// teardown and replayed after live registered-window resolution.
    let recoverableRouteLedger = RecoverableWindowRouteLedger<RecoverableMainWindowRoute>()

    /// Wires AppDelegate/window-lifecycle lookups into the registry once at the
    /// composition root, before main windows are created.
    func configureHostSeams(_ seams: WindowRegistryHostSeams) {
        hostSeams = seams
    }

    /// The context registered for `id`, or `nil` if no window has one.
    func context(for id: WindowID) -> WindowContext? {
        store.model(for: id)
    }

    /// Registers `context` for `id`, replacing any prior context for that window.
    func setContext(_ context: WindowContext, for id: WindowID) {
        store.setModel(context, for: id)
    }

    /// Removes and returns the context registered for `id`, if any. Called by the
    /// window-teardown funnel; idempotent if already gone.
    @discardableResult
    func removeContext(for id: WindowID) -> WindowContext? {
        store.remove(id)
    }

    /// The ``WindowID`` of every window that currently has a context, in no
    /// guaranteed order. Backs the coordinator's `registeredWindowIds`.
    var ids: [WindowID] {
        store.ids
    }

    /// Every registered context, in no guaranteed order. Mirrors the legacy
    /// aggregate-wide sweeps (e.g. reloading every window's config store).
    var contexts: [WindowContext] {
        store.models
    }

    private var registeredMainWindows: [AppDelegate.RegisteredMainWindow] {
        hostSeams.registeredMainWindows()
    }

    private func registeredMainWindow(forManager tabManager: TabManager) -> AppDelegate.RegisteredMainWindow? {
        hostSeams.registeredMainWindowForManager(tabManager)
    }

    private func registeredMainWindow(forWindowId windowId: UUID) -> AppDelegate.RegisteredMainWindow? {
        hostSeams.registeredMainWindowForWindowId(windowId)
    }

    private func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> AppDelegate.RegisteredMainWindow? {
        hostSeams.contextForMainTerminalWindow(window, reindex)
    }

    private func mainWindowId(from window: NSWindow) -> UUID? {
        hostSeams.mainWindowIdFromWindow(window)
    }

    private func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        hostSeams.windowForMainWindowId(windowId)
    }

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
        recoverableRouteLedger.sortedByMostRecentFirst()
    }

    private func recoverableMainWindowRouteSnapshot(windowId: UUID) -> MainWindowRouteSnapshot? {
        guard let route = recoverableRouteLedger.route(for: WindowID(windowId)),
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
        let before = recoverableRouteLedger.count
        recoverableRouteLedger.retainRoutes { _, route in
            guard let manager = route.tabManager else { return false }
            guard let window = liveRecoverableMainWindow(windowId: route.windowId, cachedWindow: route.window) else { return false }
            route.window = window
            return tabManagerHasRegisteredTerminalSurface(manager)
        }
        let after = recoverableRouteLedger.count
#if DEBUG
        if after != before {
            cmuxDebugLog("recoverableRoute.prune reason=\(reason) removed=\(before - after) remaining=\(after)")
        }
#endif
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        if recoverableRouteLedger.remove(WindowID(windowId)) != nil {
#if DEBUG
            cmuxDebugLog("recoverableRoute.forget windowId=\(String(windowId.uuidString.prefix(8)))")
#endif
        }
    }

    func rememberRecoverableMainWindowRoute(windowId: UUID, tabManager: TabManager, window: NSWindow?) {
        guard let window = liveRecoverableMainWindow(windowId: windowId, cachedWindow: window) else { return }
        guard tabManagerHasRegisteredTerminalSurface(tabManager) else { return }
        let order = recoverableRouteLedger.issueOrder()
        recoverableRouteLedger.setRoute(
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
        return recoverableRouteLedger.route(for: WindowID(windowId))
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
        recoverableRouteLedger.appendingDeduplicatedProjections(into: &summaries, seen: &seen) { route in
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

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
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

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in registeredMainWindows {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for ws in manager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (route.windowId, ws.id, manager)
                }
            }
        }
        return nil
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in registeredMainWindows {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for workspace in manager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (route.windowId, workspace.id, panelId, manager)
                }
            }
        }
        return nil
    }

    func workspaceFor(tabId: UUID) -> Workspace? {
        tabManagerFor(tabId: tabId)?.tabs.first(where: { $0.id == tabId })
    }

    private func scriptableMainWindow(for window: NSWindow) -> AppDelegate.ScriptableMainWindowState? {
        if let context = contextForMainTerminalWindow(window, reindex: false) {
            return AppDelegate.ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            )
        }

        if let windowId = mainWindowId(from: window),
           let snapshot = recoverableMainWindowRouteSnapshot(windowId: windowId) {
            return AppDelegate.ScriptableMainWindowState(
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
            return AppDelegate.ScriptableMainWindowState(
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

    func currentScriptableMainWindow() -> AppDelegate.ScriptableMainWindowState? {
        makeOrderedMainWindowResolver().resolve(
            project: { scriptableMainWindow(for: $0) },
            fallback: { scriptableMainWindows().first }
        )
    }

    func scriptableMainWindows() -> [AppDelegate.ScriptableMainWindowState] {
        var results: [AppDelegate.ScriptableMainWindowState] = []
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
                AppDelegate.ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        recoverableRouteLedger.appendingDeduplicatedProjections(into: &results, seen: &seen) { route in
            guard let snapshot = recoverableMainWindowRouteSnapshot(windowId: route.windowId) else { return nil }
            return (
                id: WindowID(snapshot.windowId),
                projection: AppDelegate.ScriptableMainWindowState(
                    windowId: snapshot.windowId,
                    tabManager: snapshot.tabManager,
                    window: snapshot.window
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> AppDelegate.ScriptableMainWindowState? {
        if let context = registeredMainWindow(forWindowId: windowId),
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            return AppDelegate.ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
        guard let snapshot = recoverableMainWindowRouteSnapshot(windowId: windowId) else { return nil }
        return AppDelegate.ScriptableMainWindowState(
            windowId: snapshot.windowId,
            tabManager: snapshot.tabManager,
            window: snapshot.window
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> AppDelegate.ScriptableMainWindowState? {
        if let context = contextContainingTabId(tabId) {
            guard let window = context.window ?? windowForMainWindowId(context.windowId) else { return nil }
            return AppDelegate.ScriptableMainWindowState(
                windowId: context.windowId,
                tabManager: context.tabManager,
                window: window
            )
        }
        for snapshot in recoverableMainWindowRouteSnapshots() {
            guard snapshot.tabManager.tabs.contains(where: { $0.id == tabId }) else {
                continue
            }
            return AppDelegate.ScriptableMainWindowState(
                windowId: snapshot.windowId,
                tabManager: snapshot.tabManager,
                window: snapshot.window
            )
        }
        return nil
    }

    func contextContainingTabId(_ tabId: UUID) -> AppDelegate.RegisteredMainWindow? {
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
