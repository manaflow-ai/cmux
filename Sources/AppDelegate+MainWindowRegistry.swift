import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Main window context registry
extension AppDelegate {
    private func notifyMainWindowContextsDidChange() {
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: self)
    }

    func ensureMobileWorkspaceListObserver(for tabManager: TabManager) {
        let id = ObjectIdentifier(tabManager)
        if mobileWorkspaceListObservers[id] == nil {
            mobileWorkspaceListObservers[id] = MobileWorkspaceListObserver(tabManager: tabManager)
        }
    }

    private func removeMobileWorkspaceListObserverIfUnused(for tabManager: TabManager) {
        guard !mainWindowContexts.values.contains(where: { $0.tabManager === tabManager }) else {
            return
        }
        mobileWorkspaceListObservers.removeValue(forKey: ObjectIdentifier(tabManager))
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState? = nil,
        cmuxConfigStore: CmuxConfigStore? = nil
    ) {
        let key = ObjectIdentifier(window)
        forgetRecoverableMainWindowRoute(windowId: windowId)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            tabManager.window = window
            existing.window = window
            let resolvedFileExplorerState = fileExplorerState ?? existing.fileExplorerState
            if let fileExplorerState {
                existing.fileExplorerState = fileExplorerState
            }
            existing.keyboardFocusCoordinator.update(
                window: window,
                tabManager: tabManager,
                fileExplorerState: resolvedFileExplorerState
            )
            if let cmuxConfigStore {
                existing.cmuxConfigStore = cmuxConfigStore
            }
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if let existingWindow = existing.window,
               existingWindow !== window,
               existingWindow.isVisible || existingWindow.isMiniaturized {
#if DEBUG
                cmuxDebugLog(
                    "mainWindow.register.duplicateIgnored windowId=\(String(windowId.uuidString.prefix(8))) " +
                        "existing={\(debugWindowToken(existingWindow))} duplicate={\(debugWindowToken(window))}"
                )
#endif
                existing.tabManager.window = existingWindow
                existing.keyboardFocusCoordinator.update(
                    window: existingWindow,
                    tabManager: existing.tabManager,
                    fileExplorerState: existing.fileExplorerState
                )
                window.orderOut(nil)
                window.close()
                return
            }
            tabManager.window = window
            existing.window = window
            let resolvedFileExplorerState = fileExplorerState ?? existing.fileExplorerState
            if let fileExplorerState {
                existing.fileExplorerState = fileExplorerState
            }
            existing.keyboardFocusCoordinator.update(
                window: window,
                tabManager: tabManager,
                fileExplorerState: resolvedFileExplorerState
            )
            if let cmuxConfigStore {
                existing.cmuxConfigStore = cmuxConfigStore
            }
            reindexMainWindowContextIfNeeded(existing, for: window)
        } else {
            tabManager.window = window
            mainWindowContexts[key] = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                fileExplorerState: fileExplorerState,
                cmuxConfigStore: cmuxConfigStore,
                window: window
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.unregisterMainWindow(closing)
            }
        }
        commandPaletteVisibilityByWindowId[windowId] = false
        commandPaletteSelectionByWindowId[windowId] = 0
        commandPaletteSnapshotByWindowId[windowId] = .empty

#if DEBUG
        cmuxDebugLog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        ensureSocketListenerIfEnabled(tabManager: tabManager, source: "mainWindow.register")
        ensureMobileWorkspaceListObserver(for: tabManager)
        notifyMainWindowContextsDidChange()
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        let didApplyStartupSessionRestore = attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if Self.shouldSaveSessionSnapshotAfterMainWindowRegistration(
            isTerminatingApp: isTerminatingApp,
            didApplyStartupSessionRestore: didApplyStartupSessionRestore,
            isApplyingSessionRestore: isApplyingSessionRestore
        ) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }

#if DEBUG
    @discardableResult
    func registerMainWindowContextForTesting(
        windowId: UUID = UUID(),
        tabManager: TabManager,
        cmuxConfigStore: CmuxConfigStore? = nil,
        fileExplorerState: FileExplorerState? = nil
    ) -> UUID {
        mainWindowContexts[ObjectIdentifier(tabManager)] = MainWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            window: nil
        )
        ensureMobileWorkspaceListObserver(for: tabManager)
        notifyMainWindowContextsDidChange()
        return windowId
    }

    func sessionSnapshotForTesting(includeScrollback: Bool = false) -> AppSessionSnapshot? {
        buildSessionSnapshot(includeScrollback: includeScrollback)
    }

#endif

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = scriptableMainWindow(windowId: windowId),
              let window = state.window else {
            return false
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }
        return true
    }

    @discardableResult
    func addWorkspace(windowId: UUID, workingDirectory: String? = nil, bringToFront shouldBringToFront: Bool = false) -> UUID? {
        guard let state = scriptableMainWindow(windowId: windowId) else { return nil }
        if shouldBringToFront, let window = state.window {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = state.tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: shouldBringToFront
        )
        return workspace.id
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        if let window = context.window {
            return window
        }
        guard let window = windowForMainWindowId(context.windowId) else {
            return nil
        }
        reindexMainWindowContextIfNeeded(context, for: window)
        return window
    }

    func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            return
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        if let conflicting = mainWindowContexts[desiredKey], conflicting !== context {
            context.window = window
            return
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
        notifyMainWindowContextsDidChange()
    }

    func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = contextForMainTerminalWindow(window, reindex: false) else { return nil }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        rememberRecoverableMainWindowRoute(windowId: removed.windowId, tabManager: removed.tabManager, window: removed.window)
        removeMobileWorkspaceListObserverIfUnused(for: removed.tabManager)
        notifyMainWindowContextsDidChange()
        return removed
    }

    func discardOrphanedMainWindowContext(_ context: MainWindowContext, allowWindowlessFallback: Bool = false) {
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        rememberRecoverableMainWindowRoute(windowId: context.windowId, tabManager: context.tabManager, window: context.window)
        removeMobileWorkspaceListObserverIfUnused(for: context.tabManager)
        notifyMainWindowContextsDidChange()

        commandPaletteVisibilityByWindowId.removeValue(forKey: context.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: context.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(context.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: context.windowId)

        if tabManager === context.tabManager {
            activateMainWindowContext(Array(mainWindowContexts.values).first { resolvedWindow(for: $0) != nil } ?? (allowWindowlessFallback ? mainWindowContexts.values.first : nil))
        }

        if let store = notificationStore {
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
    }

    func pruneWindowlessMainWindowContexts() {
        for context in Array(mainWindowContexts.values) where resolvedWindow(for: context) == nil {
            discardOrphanedMainWindowContext(context)
        }
    }

#if DEBUG
    func unregisterMainWindowContextForTesting(windowId: UUID) {
        mainWindowContexts.values.filter { $0.windowId == windowId }.forEach { discardOrphanedMainWindowContext($0, allowWindowlessFallback: true) }
    }
#endif

    func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window else { return nil }
        return contextForMainTerminalWindow(window)
    }

    private func liveMainWindowContext(for tabManager: TabManager) -> MainWindowContext? {
        for context in Array(mainWindowContexts.values) where context.tabManager === tabManager {
            if resolvedWindow(for: context) != nil {
                return context
            }
        }
        return nil
    }

    func activeTabManagerForCommands(preferredWindow: NSWindow? = nil) -> TabManager? {
        if let context = contextForMainWindow(preferredWindow) {
            return context.tabManager
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context.tabManager
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           let activeContext = liveMainWindowContext(for: activeManager) {
            return activeContext.tabManager
        }
        return mainWindowContexts.values.first { context in
            resolvedWindow(for: context) != nil
        }?.tabManager
    }

    func allMainWindowTabManagersForDebug() -> [TabManager] {
        Array(mainWindowContexts.values).compactMap { context in
            resolvedWindow(for: context) == nil ? nil : context.tabManager
        }
    }
#if DEBUG
    func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        cmuxDebugLog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive {
#if DEBUG
            cmuxDebugLog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} nochange=1 \(debugShortcutRouteSnapshot())"
            )
#endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            fileExplorerState = context.fileExplorerState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        cmuxDebugLog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
    }

}
