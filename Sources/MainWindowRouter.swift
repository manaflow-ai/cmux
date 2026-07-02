import AppKit
import Bonsplit
import CmuxSettings
import CmuxSidebar
import CmuxWindowing
import CmuxWorkspaces
import Foundation

@MainActor
struct MainWindowRouterHostSeams {
    let shortcutRoutingKeyWindow: @MainActor () -> NSWindow?
    let contextForMainWindow: @MainActor (NSWindow?) -> AppDelegate.RegisteredMainWindow?
    let registeredMainWindows: @MainActor () -> [AppDelegate.RegisteredMainWindow]
    let registeredMainWindowForManager: @MainActor (TabManager) -> AppDelegate.RegisteredMainWindow?
    let resolvedWindow: @MainActor (AppDelegate.RegisteredMainWindow) -> NSWindow?
    let windowForMainWindowId: @MainActor (UUID) -> NSWindow?
    let setActiveMainWindow: @MainActor (NSWindow) -> Void
    let discardOrphanedMainWindowContext: @MainActor (AppDelegate.RegisteredMainWindow) -> Void
    let focusMainWindow: @MainActor (UUID) -> Bool
    let closeMainWindow: @MainActor (UUID, Bool) -> Bool
    let discardMainWindowWithoutClosedHistory: @MainActor (UUID) -> Void
    let closeWindowContainingTabId: @MainActor (UUID, Bool) -> Void
    let createMainWindow: @MainActor () -> UUID?
    let focusForInWindowCommand: @MainActor (NSWindow, MainWindowVisibilityController.Reason) -> Void
    let setActiveTerminalControlTabManager: @MainActor (TabManager?) -> Void
    let reassertCrossWindowSurfaceMoveFocus: @MainActor (UUID, UUID, UUID, UUID, TabManager) -> Void
    let paneSurfaceMoveTargets: @MainActor ([PaneSurfaceMoveWindowSummary], UUID?) -> [AppDelegate.WorkspaceMoveTarget]
    let bringToFront: @MainActor (NSWindow) -> Void
    let showMainWindowFromMenuBar: @MainActor () -> NSWindow?
    let activateMainWindowFromSocket: @MainActor () -> Bool
    let focusWindowForAppActivation: @MainActor (NSWindow, MainWindowVisibilityController.Reason) -> Bool
    let preferredWindowForSettingsPresentation: @MainActor () -> NSWindow?
    let performNewWorkspaceAction: @MainActor (TabManager?, NSEvent?, String) -> Bool
    let performNewBrowserWorkspaceAction: @MainActor (TabManager?, NSEvent?, String) -> Bool
    let performCloudVMAction: @MainActor (TabManager?, NSWindow?, String, ((CloudVMActionCompletion) -> Void)?) -> Bool
    let showNewWorkspaceContextMenu: @MainActor (NSView, NSEvent, String) -> Bool
    let showOpenFolderInInlineVSCodePanel: @MainActor (TabManager?) -> Void
    let showFocusHistoryContextMenu: @MainActor (NSView, NSEvent, FocusHistoryMenuDirection, Bool, String) -> Bool
#if DEBUG
    // `var` with defaults (set via statement-level `#if DEBUG` at the wiring
    // site) rather than memberwise-init parameters: `#if` cannot split a
    // parameter clause, so conditional fields must stay out of the init.
    var debugManagerToken: @MainActor (TabManager?) -> String = { _ in "nil" }
    var debugWindowToken: @MainActor (NSWindow?) -> String = { _ in "nil" }
    var debugContextToken: @MainActor (AppDelegate.RegisteredMainWindow?) -> String = { _ in "nil" }
    var debugRouteSnapshot: @MainActor (NSEvent?) -> String = { _ in "" }
#endif

    init(
        shortcutRoutingKeyWindow: @escaping @MainActor () -> NSWindow? = { nil },
        contextForMainWindow: @escaping @MainActor (NSWindow?) -> AppDelegate.RegisteredMainWindow? = { _ in nil },
        registeredMainWindows: @escaping @MainActor () -> [AppDelegate.RegisteredMainWindow] = { [] },
        registeredMainWindowForManager: @escaping @MainActor (TabManager) -> AppDelegate.RegisteredMainWindow? = { _ in nil },
        resolvedWindow: @escaping @MainActor (AppDelegate.RegisteredMainWindow) -> NSWindow? = { _ in nil },
        windowForMainWindowId: @escaping @MainActor (UUID) -> NSWindow? = { _ in nil },
        setActiveMainWindow: @escaping @MainActor (NSWindow) -> Void = { _ in },
        discardOrphanedMainWindowContext: @escaping @MainActor (AppDelegate.RegisteredMainWindow) -> Void = { _ in },
        focusMainWindow: @escaping @MainActor (UUID) -> Bool = { _ in false },
        closeMainWindow: @escaping @MainActor (UUID, Bool) -> Bool = { _, _ in false },
        discardMainWindowWithoutClosedHistory: @escaping @MainActor (UUID) -> Void = { _ in },
        closeWindowContainingTabId: @escaping @MainActor (UUID, Bool) -> Void = { _, _ in },
        createMainWindow: @escaping @MainActor () -> UUID? = { nil },
        focusForInWindowCommand: @escaping @MainActor (NSWindow, MainWindowVisibilityController.Reason) -> Void = { _, _ in },
        setActiveTerminalControlTabManager: @escaping @MainActor (TabManager?) -> Void = { _ in },
        reassertCrossWindowSurfaceMoveFocus: @escaping @MainActor (UUID, UUID, UUID, UUID, TabManager) -> Void = { _, _, _, _, _ in },
        paneSurfaceMoveTargets: @escaping @MainActor ([PaneSurfaceMoveWindowSummary], UUID?) -> [AppDelegate.WorkspaceMoveTarget] = { _, _ in [] },
        bringToFront: @escaping @MainActor (NSWindow) -> Void = { _ in },
        showMainWindowFromMenuBar: @escaping @MainActor () -> NSWindow? = { nil },
        activateMainWindowFromSocket: @escaping @MainActor () -> Bool = { false },
        focusWindowForAppActivation: @escaping @MainActor (NSWindow, MainWindowVisibilityController.Reason) -> Bool = { _, _ in false },
        preferredWindowForSettingsPresentation: @escaping @MainActor () -> NSWindow? = { nil },
        performNewWorkspaceAction: @escaping @MainActor (TabManager?, NSEvent?, String) -> Bool = { _, _, _ in false },
        performNewBrowserWorkspaceAction: @escaping @MainActor (TabManager?, NSEvent?, String) -> Bool = { _, _, _ in false },
        performCloudVMAction: @escaping @MainActor (TabManager?, NSWindow?, String, ((CloudVMActionCompletion) -> Void)?) -> Bool = { _, _, _, _ in false },
        showNewWorkspaceContextMenu: @escaping @MainActor (NSView, NSEvent, String) -> Bool = { _, _, _ in false },
        showOpenFolderInInlineVSCodePanel: @escaping @MainActor (TabManager?) -> Void = { _ in },
        showFocusHistoryContextMenu: @escaping @MainActor (NSView, NSEvent, FocusHistoryMenuDirection, Bool, String) -> Bool = { _, _, _, _, _ in false }
    ) {
        self.shortcutRoutingKeyWindow = shortcutRoutingKeyWindow
        self.contextForMainWindow = contextForMainWindow
        self.registeredMainWindows = registeredMainWindows
        self.registeredMainWindowForManager = registeredMainWindowForManager
        self.resolvedWindow = resolvedWindow
        self.windowForMainWindowId = windowForMainWindowId
        self.setActiveMainWindow = setActiveMainWindow
        self.discardOrphanedMainWindowContext = discardOrphanedMainWindowContext
        self.focusMainWindow = focusMainWindow
        self.closeMainWindow = closeMainWindow
        self.discardMainWindowWithoutClosedHistory = discardMainWindowWithoutClosedHistory
        self.closeWindowContainingTabId = closeWindowContainingTabId
        self.createMainWindow = createMainWindow
        self.focusForInWindowCommand = focusForInWindowCommand
        self.setActiveTerminalControlTabManager = setActiveTerminalControlTabManager
        self.reassertCrossWindowSurfaceMoveFocus = reassertCrossWindowSurfaceMoveFocus
        self.paneSurfaceMoveTargets = paneSurfaceMoveTargets
        self.bringToFront = bringToFront
        self.showMainWindowFromMenuBar = showMainWindowFromMenuBar
        self.activateMainWindowFromSocket = activateMainWindowFromSocket
        self.focusWindowForAppActivation = focusWindowForAppActivation
        self.preferredWindowForSettingsPresentation = preferredWindowForSettingsPresentation
        self.performNewWorkspaceAction = performNewWorkspaceAction
        self.performNewBrowserWorkspaceAction = performNewBrowserWorkspaceAction
        self.performCloudVMAction = performCloudVMAction
        self.showNewWorkspaceContextMenu = showNewWorkspaceContextMenu
        self.showOpenFolderInInlineVSCodePanel = showOpenFolderInInlineVSCodePanel
        self.showFocusHistoryContextMenu = showFocusHistoryContextMenu
    }
}

@MainActor
final class MainWindowRouter {
    private let windowRegistry: WindowRegistry
    private var hostSeams = MainWindowRouterHostSeams()

    weak var activeTabManager: TabManager?
    weak var activeSidebarState: SidebarState?
    weak var activeSidebarSelectionState: SidebarSelectionState?
    weak var activeFileExplorerState: FileExplorerState?

    init(windowRegistry: WindowRegistry) {
        self.windowRegistry = windowRegistry
    }

    func configureHostSeams(_ seams: MainWindowRouterHostSeams) {
        hostSeams = seams
    }

    private var shortcutRoutingKeyWindow: NSWindow? {
        hostSeams.shortcutRoutingKeyWindow()
    }

    private var registeredMainWindows: [AppDelegate.RegisteredMainWindow] {
        hostSeams.registeredMainWindows()
    }

    private func contextForMainWindow(_ window: NSWindow?) -> AppDelegate.RegisteredMainWindow? {
        hostSeams.contextForMainWindow(window)
    }

    private func registeredMainWindow(forManager tabManager: TabManager) -> AppDelegate.RegisteredMainWindow? {
        hostSeams.registeredMainWindowForManager(tabManager)
    }

    private func resolvedWindow(for context: AppDelegate.RegisteredMainWindow) -> NSWindow? {
        hostSeams.resolvedWindow(context)
    }

    private func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        hostSeams.windowForMainWindowId(windowId)
    }

    private func sidebarSelectionState(for context: AppDelegate.RegisteredMainWindow) -> SidebarSelectionState {
        if let wctx = windowRegistry.context(for: WindowID(context.windowId)) {
            return wctx.sidebarSelectionState
        }
        return SidebarSelectionState()
    }

    private func sidebarState(for context: AppDelegate.RegisteredMainWindow) -> SidebarState {
        if let wctx = windowRegistry.context(for: WindowID(context.windowId)) {
            return wctx.sidebarState
        }
        return SidebarState()
    }

    private func fileExplorerState(for context: AppDelegate.RegisteredMainWindow) -> FileExplorerState? {
        windowRegistry.context(for: WindowID(context.windowId))?.fileExplorerState
    }

    func preferredRegisteredMainWindowContext(preferredWindow: NSWindow? = nil) -> AppDelegate.RegisteredMainWindow? {
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow) {
            return context
        }
        if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = activeTabManager,
           let activeContext = registeredMainWindow(forManager: activeManager) {
            return activeContext
        }
        return registeredMainWindows.first
    }

    func activeTabManagerForCommands(preferredWindow: NSWindow? = nil) -> TabManager? {
        if let context = contextForMainWindow(preferredWindow) {
            return context.tabManager
        }
        if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
            return context.tabManager
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context.tabManager
        }
        if let activeManager = activeTabManager,
           let activeContext = liveMainWindowContext(for: activeManager) {
            return activeContext.tabManager
        }
        return registeredMainWindows.first { context in
            resolvedWindow(for: context) != nil
        }?.tabManager
    }

    private func liveMainWindowContext(for tabManager: TabManager) -> AppDelegate.RegisteredMainWindow? {
        for context in Array(registeredMainWindows) where context.tabManager === tabManager {
            if resolvedWindow(for: context) != nil {
                return context
            }
        }
        return nil
    }

    @discardableResult
    func synchronizeActiveWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (AppDelegate.RegisteredMainWindow?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = activeTabManager,
               let activeContext = registeredMainWindow(forManager: activeManager) {
                return (activeContext, "activeManager")
            }
            return (registeredMainWindows.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = hostSeams.debugManagerToken(activeTabManager)
        cmuxDebugLog(
            "shortcut.sync.pre source=\(source) preferred={\(hostSeams.debugWindowToken(preferredWindow))} chosen={\(hostSeams.debugContextToken(context))} \(hostSeams.debugRouteSnapshot(nil))"
        )
#endif
        guard let context else { return activeTabManager }
        let alreadyActive =
            activeTabManager === context.tabManager
            && activeSidebarState === sidebarState(for: context)
            && activeSidebarSelectionState === sidebarSelectionState(for: context)
        if alreadyActive {
#if DEBUG
            cmuxDebugLog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(hostSeams.debugManagerToken(activeTabManager)) chosen={\(hostSeams.debugContextToken(context))} nochange=1 \(hostSeams.debugRouteSnapshot(nil))"
            )
#endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            hostSeams.setActiveMainWindow(window)
        } else {
            activeTabManager = context.tabManager
            activeSidebarState = sidebarState(for: context)
            activeSidebarSelectionState = sidebarSelectionState(for: context)
            activeFileExplorerState = fileExplorerState(for: context)
            hostSeams.setActiveTerminalControlTabManager(context.tabManager)
        }
#if DEBUG
        cmuxDebugLog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(hostSeams.debugManagerToken(activeTabManager)) chosen={\(hostSeams.debugContextToken(context))} \(hostSeams.debugRouteSnapshot(nil))"
        )
#endif
        return context.tabManager
    }

    func repointActiveWindow(to context: AppDelegate.RegisteredMainWindow?) {
        guard let context else {
            activeTabManager = nil
            activeSidebarState = nil
            activeSidebarSelectionState = nil
            activeFileExplorerState = nil
            hostSeams.setActiveTerminalControlTabManager(nil)
            return
        }
        activeTabManager = context.tabManager
        activeSidebarState = sidebarState(for: context)
        activeSidebarSelectionState = sidebarSelectionState(for: context)
        activeFileExplorerState = fileExplorerState(for: context)
        hostSeams.setActiveTerminalControlTabManager(context.tabManager)
    }

    func setActiveWindowContext(_ context: AppDelegate.RegisteredMainWindow, keyWindow window: NSWindow) {
#if DEBUG
        let beforeManagerToken = hostSeams.debugManagerToken(activeTabManager)
#endif
        repointActiveWindow(to: context)
#if DEBUG
        cmuxDebugLog(
            "mainWindow.active window={\(hostSeams.debugWindowToken(window))} context={\(hostSeams.debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(hostSeams.debugManagerToken(activeTabManager)) \(hostSeams.debugRouteSnapshot(nil))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        func toggle(_ context: AppDelegate.RegisteredMainWindow) -> Bool {
            guard let window = resolvedWindow(for: context) else {
                hostSeams.discardOrphanedMainWindowContext(context)
                return false
            }
            hostSeams.setActiveMainWindow(window)
            sidebarState(for: context).toggle()
            return true
        }

        if let preferredWindow,
           let preferredContext = contextForMainWindow(preferredWindow),
           toggle(preferredContext) {
            return true
        }
        if let keyWindow = shortcutRoutingKeyWindow,
           let keyContext = contextForMainWindow(keyWindow),
           toggle(keyContext) {
            return true
        }
        if let mainWindow = NSApp.mainWindow,
           let mainContext = contextForMainWindow(mainWindow),
           toggle(mainContext) {
            return true
        }
        if let activeManager = activeTabManager,
           let activeContext = registeredMainWindow(forManager: activeManager),
           toggle(activeContext) {
            return true
        }
        for fallbackContext in Array(registeredMainWindows) where toggle(fallbackContext) {
            return true
        }
        return false
    }

    @discardableResult
    func toggleRightSidebarInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            if let activeFileExplorerState {
                activeFileExplorerState.toggle()
                return true
            }
            return false
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            hostSeams.setActiveMainWindow(window)
        }

        guard let state = fileExplorerState(for: context) ?? activeFileExplorerState else {
            return false
        }
        let wasVisible = state.isVisible
        state.toggle()
        if wasVisible && !state.isVisible {
            _ = context.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
        }
        return true
    }

    @discardableResult
    func closeRightSidebarInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            guard let activeFileExplorerState else {
                return false
            }
            activeFileExplorerState.setVisible(false)
            return true
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            hostSeams.setActiveMainWindow(window)
        }

        guard let state = fileExplorerState(for: context) ?? activeFileExplorerState else {
            return false
        }
        let wasVisible = state.isVisible
        state.setVisible(false)
        if wasVisible && !state.isVisible {
            _ = context.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
        }
        return true
    }

    @discardableResult
    func focusRightSidebarInActiveWindow(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.app.abort reason=noContext preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
                "\(hostSeams.debugRouteSnapshot(nil))"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforeState = fileExplorerState(for: context) ?? activeFileExplorerState
        dlog(
            "rs.focus.app.begin preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
            "context={\(hostSeams.debugContextToken(context))} targetWin={\(hostSeams.debugWindowToken(window))} " +
            "visible=\((beforeState?.isVisible ?? false) ? 1 : 0) mode=\(beforeState?.mode.rawValue ?? "nil") " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            hostSeams.focusForInWindowCommand(window, .rightSidebarFocus)
        }
        let result = context.keyboardFocusCoordinator.focusRightSidebar(
            mode: requestedMode,
            focusFirstItem: focusFirstItem
        )
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.app.end requested=1 result=\(result ? 1 : 0) " +
            "mode=\(requestedMode?.rawValue ?? (fileExplorerState(for: context)?.mode.rawValue ?? "nil")) " +
            "targetWin={\(hostSeams.debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

#if DEBUG
    func debugRevealRightSidebarInActiveWindow(
        mode: RightSidebarMode,
        focusFirstItem: Bool,
        preferredWindow: NSWindow? = nil
    ) -> (
        revealed: Bool,
        focusApplied: Bool,
        contextFound: Bool,
        stateFound: Bool,
        visible: Bool,
        activeMode: String?
    ) {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)
        let window = context.flatMap { $0.window ?? windowForMainWindowId($0.windowId) }
        if let window {
            if !window.isKeyWindow {
                if !NSApp.isActive {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
                window.makeKeyAndOrderFront(nil)
            }
            hostSeams.setActiveMainWindow(window)
        }

        guard let state = context.flatMap({ fileExplorerState(for: $0) }) ?? activeFileExplorerState else {
            return (
                revealed: false,
                focusApplied: false,
                contextFound: context != nil,
                stateFound: false,
                visible: false,
                activeMode: nil
            )
        }

        if state.mode != mode {
            state.mode = mode
        }
        state.setVisible(true)

        let focusApplied = context?.keyboardFocusCoordinator.focusRightSidebar(
            mode: mode,
            focusFirstItem: focusFirstItem
        ) ?? false

        return (
            revealed: state.isVisible && state.mode == mode,
            focusApplied: focusApplied,
            contextFound: context != nil,
            stateFound: true,
            visible: state.isVisible,
            activeMode: state.mode.rawValue
        )
    }
#endif

    @discardableResult
    func focusFileSearchInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "file.search.focus.app.abort reason=noContext preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
                "\(hostSeams.debugRouteSnapshot(nil))"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.begin preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
            "context={\(hostSeams.debugContextToken(context))} targetWin={\(hostSeams.debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            hostSeams.focusForInWindowCommand(window, .fileSearchFocus)
        }
        let result = context.keyboardFocusCoordinator.focusFileSearch()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.end result=\(result ? 1 : 0) " +
            "targetWin={\(hostSeams.debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func performFindInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "find.shortcut.app.abort reason=noContext preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
                "\(hostSeams.debugRouteSnapshot(nil))"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.begin preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
            "context={\(hostSeams.debugContextToken(context))} targetWin={\(hostSeams.debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        let target = context.keyboardFocusCoordinator.findShortcutTarget(
            currentResponder: window?.firstResponder
        )
        guard target != .none else {
#if DEBUG
            dlog(
                "find.shortcut.app.end target=\(target) result=0 " +
                "targetWin={\(hostSeams.debugWindowToken(window))} fr=\(beforeResponder)"
            )
#endif
            return false
        }

        if let window {
            hostSeams.focusForInWindowCommand(window, .findShortcut)
        }

        let result: Bool
        switch target {
        case .rightSidebarFileSearch:
            result = context.keyboardFocusCoordinator.focusFileSearch()
        case .mainPanelFind:
            result = context.tabManager.startSearch()
        case .none:
            return false
        }
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.end target=\(target) result=\(result ? 1 : 0) " +
            "targetWin={\(hostSeams.debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func toggleRightSidebarKeyboardFocusInActiveWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.toggle.abort reason=noContext preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
                "\(hostSeams.debugRouteSnapshot(nil))"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.begin preferred={\(hostSeams.debugWindowToken(preferredWindow))} " +
            "context={\(hostSeams.debugContextToken(context))} targetWin={\(hostSeams.debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            hostSeams.focusForInWindowCommand(window, .rightSidebarToggle)
        }
        let result = context.keyboardFocusCoordinator.toggleRightSidebarOrTerminalFocus()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.end result=\(result ? 1 : 0) " +
            "targetWin={\(hostSeams.debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [AppDelegate.WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard windowRegistry.tabManagerFor(windowId: summary.windowId) != nil else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return AppDelegate.WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [AppDelegate.WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        let summaries: [PaneSurfaceMoveWindowSummary] = orderedSummaries.compactMap { summary in
            guard let manager = windowRegistry.tabManagerFor(windowId: summary.windowId) else { return nil }
            return PaneSurfaceMoveWindowSummary(
                windowId: summary.windowId,
                windowLabel: labels[summary.windowId] ?? "Window",
                isCurrentWindow: summary.windowId == referenceWindowId,
                workspaces: manager.tabs.map { workspace in
                    PaneSurfaceMoveWindowSummary.Workspace(
                        workspaceId: workspace.id,
                        title: workspaceDisplayName(workspace)
                    )
                }
            )
        }

        return hostSeams.paneSurfaceMoveTargets(summaries, excludingWorkspaceId)
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, atIndex: Int? = nil, focus: Bool = true) -> Bool {
        guard let sourceManager = windowRegistry.tabManagerFor(tabId: workspaceId),
              let destinationManager = windowRegistry.tabManagerFor(windowId: windowId) else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = hostSeams.focusMainWindow(windowId)
                hostSeams.setActiveTerminalControlTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, at: atIndex, select: focus)

        if focus {
            _ = hostSeams.focusMainWindow(windowId)
            hostSeams.setActiveTerminalControlTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        guard let windowId = hostSeams.createMainWindow() else { return nil }
        guard let destinationManager = windowRegistry.tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = hostSeams.closeMainWindow(windowId, false)
            return nil
        }

        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1 {
            destinationManager.closeWorkspace(bootstrapWorkspace, recordHistory: false)
        }
        return windowId
    }

    @discardableResult
    func focusScriptableWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = windowRegistry.scriptableMainWindow(windowId: windowId),
              let window = state.window else {
            return false
        }
        hostSeams.setActiveMainWindow(window)
        if shouldBringToFront {
            hostSeams.bringToFront(window)
        }
        return true
    }

    func allMainWindowTabManagersForDebug() -> [TabManager] {
        Array(registeredMainWindows).compactMap { context in
            resolvedWindow(for: context) == nil ? nil : context.tabManager
        }
    }

    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let source = windowRegistry.locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return sourceWorkspace.panels.count > 1
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        guard let located = windowRegistry.locateBonsplitSurface(tabId: tabId) else { return false }
        return canMoveSurfaceToNewWorkspace(panelId: located.panelId)
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard let located = windowRegistry.locateBonsplitSurface(tabId: tabId),
              let sourceWorkspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              sourceWorkspace.panels[located.panelId] != nil,
              let destinationManager = windowRegistry.tabManagerFor(tabId: targetWorkspaceId),
              destinationManager.tabs.contains(where: { $0.id == targetWorkspaceId }) else {
            return false
        }
        return true
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [AppDelegate.WorkspaceMoveTarget] {
        guard let source = windowRegistry.locateSurface(surfaceId: panelId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: source.workspaceId,
            referenceWindowId: source.windowId
        )
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [AppDelegate.WorkspaceMoveTarget] {
        guard let located = windowRegistry.locateBonsplitSurface(tabId: tabId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: located.workspaceId,
            referenceWindowId: located.windowId
        )
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let located = windowRegistry.locateBonsplitSurface(tabId: tabId) else { return nil }
        return moveSurfaceToNewWorkspace(
            panelId: located.panelId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride
        )
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = windowRegistry.locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: detached,
            title: destinationTitle,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: activationIntent
        ) else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            return nil
        }

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )

        if focus {
            let destinationWindowId = focusWindow ? windowRegistry.windowId(for: targetManager) : nil
            if let destinationWindowId {
                _ = hostSeams.focusMainWindow(destinationWindowId)
            }
            targetManager.focusTab(
                destinationWorkspace.id,
                surfaceId: panelId,
                suppressFlash: true,
                focusIntent: activationIntent
            )
            if let destinationWindowId {
                hostSeams.reassertCrossWindowSurfaceMoveFocus(
                    destinationWindowId,
                    source.windowId,
                    destinationWorkspace.id,
                    panelId,
                    targetManager
                )
            }
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowRegistry.windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        let outcome = DetachedSourceWorkspaceCleanupPolicy().outcome(
            sourceWorkspaceIsEmpty: sourceWorkspace.panels.isEmpty,
            sourceWorkspaceStillInManager: sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }),
            sourceManagerWorkspaceCount: sourceManager.tabs.count
        )
        switch outcome {
        case .none:
            return
        case .closeWorkspace:
            sourceManager.closeWorkspace(sourceWorkspace, recordHistory: false)
        case .closeWindow:
            _ = hostSeams.closeMainWindow(sourceWindowId, false)
        }
    }

    func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        let rollbackPane = sourcePane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let rollbackPane else { return }
        _ = workspace.attachDetachedSurface(
            detached,
            inPane: rollbackPane,
            atIndex: sourceIndex,
            focus: focus
        )
    }

    @discardableResult
    func moveWindow(windowId: UUID, toDisplayMatching query: String) -> String? {
        guard let window = windowRegistry.mainWindow(for: windowId),
              let screen = NSScreen.cmuxScreen(matching: query) else { return nil }
        window.cmuxRepositionPreservingSize(onto: screen)
        return screen.localizedName
    }

    func moveAllWindows(toDisplayMatching query: String) -> (display: String, windowIds: [UUID])? {
        guard let screen = NSScreen.cmuxScreen(matching: query) else { return nil }
        var moved: [UUID] = []
        for summary in windowRegistry.listMainWindowSummaries() {
            guard let window = windowRegistry.mainWindow(for: summary.windowId) else { continue }
            window.cmuxRepositionPreservingSize(onto: screen)
            moved.append(summary.windowId)
        }
        return (screen.localizedName, moved)
    }

    @discardableResult
    func focusMainWindow(windowId: UUID) -> Bool {
        hostSeams.focusMainWindow(windowId)
    }

    @discardableResult
    func closeMainWindow(windowId: UUID, recordHistory: Bool = true) -> Bool {
        hostSeams.closeMainWindow(windowId, recordHistory)
    }

    func discardWindowWithoutHistory(windowId: UUID) {
        hostSeams.discardMainWindowWithoutClosedHistory(windowId)
    }

    func closeWindowContaining(tabId: UUID, recordHistory: Bool = true) {
        hostSeams.closeWindowContainingTabId(tabId, recordHistory)
    }

    func createMainWindow() -> UUID? {
        hostSeams.createMainWindow()
    }

    @discardableResult
    func showMainWindowFromMenuBar() -> NSWindow? {
        hostSeams.showMainWindowFromMenuBar()
    }

    @discardableResult
    func activateFromSocket() -> Bool {
        hostSeams.activateMainWindowFromSocket()
    }

    @discardableResult
    func focusWindowForAppActivation(
        _ window: NSWindow,
        reason: MainWindowVisibilityController.Reason
    ) -> Bool {
        hostSeams.focusWindowForAppActivation(window, reason)
    }

    func preferredWindowForSettingsPresentation() -> NSWindow? {
        hostSeams.preferredWindowForSettingsPresentation()
    }

    @discardableResult
    func performNewWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newWorkspace"
    ) -> Bool {
        hostSeams.performNewWorkspaceAction(preferredTabManager, event, debugSource)
    }

    @discardableResult
    func performNewBrowserWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newBrowserWorkspace"
    ) -> Bool {
        hostSeams.performNewBrowserWorkspaceAction(preferredTabManager, event, debugSource)
    }

    @discardableResult
    func performCloudVMAction(
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "cloudVM",
        onCompletion: ((CloudVMActionCompletion) -> Void)? = nil
    ) -> Bool {
        hostSeams.performCloudVMAction(preferredTabManager, preferredWindow, debugSource, onCompletion)
    }

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        hostSeams.showNewWorkspaceContextMenu(anchorView, event, debugSource)
    }

    func showOpenFolderInInlineVSCodePanel(tabManager preferredTabManager: TabManager? = nil) {
        hostSeams.showOpenFolderInInlineVSCodePanel(preferredTabManager)
    }

    @discardableResult
    func showFocusHistoryContextMenu(
        anchorView: NSView,
        event: NSEvent,
        direction: FocusHistoryMenuDirection,
        showFullHistory: Bool = false,
        debugSource: String = "titlebar.focusHistory.contextMenu"
    ) -> Bool {
        hostSeams.showFocusHistoryContextMenu(anchorView, event, direction, showFullHistory, debugSource)
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [AppDelegate.MainWindowSummary] {
        windowRegistry.listMainWindowSummaries().orderedByReference(referenceWindowId: referenceWindowId)
    }

    private func windowLabelsById(orderedSummaries: [AppDelegate.MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    private func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        if panel is BrowserPanel {
            return .browser(.addressBar)
        }
        return panel.preferredFocusIntentForActivation()
    }

    private func titleForDetachedWorkspace(
        explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        DetachedWorkspaceTitlePolicy().title(
            explicitTitle: explicitTitle,
            surfaceTitle: workspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
            localizedFallback: String(
                localized: "commandPalette.subtitle.tabFallback",
                defaultValue: "Tab"
            )
        )
    }
}
