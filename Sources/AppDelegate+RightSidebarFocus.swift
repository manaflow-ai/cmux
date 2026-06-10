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


// MARK: - Sidebar toggles and right sidebar keyboard focus
extension AppDelegate {
    @discardableResult
    func toggleSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        func toggle(_ context: MainWindowContext) -> Bool {
            guard let window = resolvedWindow(for: context) else {
                discardOrphanedMainWindowContext(context)
                return false
            }
            setActiveMainWindow(window)
            context.sidebarState.toggle()
            return true
        }

        if let preferredWindow,
           let preferredContext = contextForMainTerminalWindow(preferredWindow),
           toggle(preferredContext) {
            return true
        }
        if let keyWindow = NSApp.keyWindow,
           let keyContext = contextForMainTerminalWindow(keyWindow),
           toggle(keyContext) {
            return true
        }
        if let mainWindow = NSApp.mainWindow,
           let mainContext = contextForMainTerminalWindow(mainWindow),
           toggle(mainContext) {
            return true
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }),
           toggle(activeContext) {
            return true
        }
        for fallbackContext in Array(mainWindowContexts.values) where toggle(fallbackContext) {
            return true
        }
        return false
    }

    @discardableResult
    func toggleRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            if let fileExplorerState {
                fileExplorerState.toggle()
                return true
            }
            return false
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            setActiveMainWindow(window)
        }

        guard let state = context.fileExplorerState ?? fileExplorerState else {
            return false
        }
        let wasVisible = state.isVisible
        state.toggle()
        if wasVisible && !state.isVisible {
            _ = context.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
        }
        return true
    }

    func applyRightSidebarRemoteCommand(
        _ command: RightSidebarRemoteCommand,
        target: RightSidebarRemoteTarget = RightSidebarRemoteTarget()
    ) -> RightSidebarRemoteApplyResult {
        let context = rightSidebarRemoteContext(target: target)
        if !target.isActiveTarget, context == nil {
            return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
        }
        let state: FileExplorerState?
        if target.isActiveTarget {
            state = context?.fileExplorerState ?? fileExplorerState
        } else {
            state = context?.fileExplorerState
        }
        guard let state else {
            return .failure(String(localized: "rightSidebar.remote.error.stateUnavailable", defaultValue: "ERROR: Right sidebar state not available"))
        }

        let preferredWindow = context.flatMap { $0.window ?? windowForMainWindowId($0.windowId) }
        let requiresWindowFocus: Bool
        switch command {
        case .focus:
            requiresWindowFocus = true
        case .setMode(_, let focus):
            requiresWindowFocus = focus
        case .toggle, .show, .hide, .getState:
            requiresWindowFocus = false
        }
        if requiresWindowFocus, !target.isActiveTarget, preferredWindow == nil {
            return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
        }

        switch command {
        case .toggle:
            guard target.isActiveTarget || preferredWindow != nil else {
                return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
            }
            guard toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.unavailable", defaultValue: "ERROR: Right sidebar not available"))
            }
            return .ok

        case .show:
            guard !state.isVisible else {
                return .ok
            }
            guard target.isActiveTarget || preferredWindow != nil else {
                return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
            }
            guard toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.unavailable", defaultValue: "ERROR: Right sidebar not available"))
            }
            return .ok

        case .hide:
            let wasVisible = state.isVisible
            state.setVisible(false)
            if wasVisible {
                _ = context?.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
            }
            return .ok

        case .focus:
            // Remote focus should preserve the currently selected sidebar mode
            // instead of reviving a stale keyboard-focus memory.
            guard focusRightSidebarInActiveMainWindow(mode: state.mode, preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus right sidebar"))
            }
            return .ok

        case .setMode(let mode, let focus):
            guard mode.isAvailable() else {
                return .failure(String(localized: "rightSidebar.remote.error.modeUnavailable", defaultValue: "ERROR: Right sidebar mode '\(mode.rawValue)' is not available"))
            }
            if focus {
                guard focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: preferredWindow) else {
                    return .failure(String(localized: "rightSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus right sidebar"))
                }
            } else {
                state.setVisible(true)
                state.mode = mode
                context?.keyboardFocusCoordinator.rememberRightSidebarMode(mode)
            }
            return .ok

        case .getState:
            return .state(.init(visible: state.isVisible, mode: state.mode))
        }
    }

    private func rightSidebarRemoteContext(target: RightSidebarRemoteTarget) -> MainWindowContext? {
        if let windowId = target.windowId {
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }
        if let workspaceId = target.workspaceId {
            return mainWindowContexts.values.first { context in
                context.tabManager.tabs.contains(where: { $0.id == workspaceId })
            }
        }
        return preferredRegisteredMainWindowContext()
    }

    @discardableResult
    func closeRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            guard let fileExplorerState else {
                return false
            }
            fileExplorerState.setVisible(false)
            return true
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            setActiveMainWindow(window)
        }

        guard let state = context.fileExplorerState ?? fileExplorerState else {
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
    func restoreTerminalFocusAfterRightSidebarHidden(in window: NSWindow?) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: window)
        return context?.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded() ?? false
    }

    @discardableResult
    func restoreFocusedMainPanelFocusFromRightSidebar(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId) ?? preferredWindow
        if let window {
            setActiveMainWindow(window)
        }
        return context.keyboardFocusCoordinator.restoreFocusedPanelFocusFromRightSidebarIfNeeded(
            currentResponder: window?.firstResponder
        )
    }

    @discardableResult
    func restoreFocusedMainPanelFocusForShortcut(event: NSEvent) -> Bool {
        let preferredWindow = mainWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        return restoreFocusedMainPanelFocusFromRightSidebar(preferredWindow: preferredWindow)
    }

    func keyboardFocusCoordinator(for window: NSWindow?) -> MainWindowFocusController? {
        guard let window else { return nil }
        return contextForMainWindow(window)?.keyboardFocusCoordinator
            ?? contextForMainTerminalWindow(window)?.keyboardFocusCoordinator
    }

    func isRightSidebarFocusResponder(_ responder: NSResponder, in window: NSWindow?) -> Bool {
        // A responder reparented out of `window` (stranded) is not this window's right-sidebar focus
        // owner even when its type matches `ownsRightSidebarFocus`. Requiring window membership keeps a
        // stranded host from being treated as a legitimate focus owner that blocks focus recovery
        // (issue #5269).
        guard let window, (responder as? NSView)?.window === window else { return false }
        return keyboardFocusCoordinator(for: window)?.ownsRightSidebarFocus(responder) == true
    }

    func shouldRouteRightSidebarModeShortcut(in window: NSWindow?) -> Bool {
        guard let window,
              let responder = window.firstResponder else {
            return false
        }
        if isRightSidebarFocusResponder(responder, in: window) {
            return true
        }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let panelId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId)
    }

    func allowsTerminalKeyboardFocus(
        workspaceId: UUID,
        panelId: UUID,
        in window: NSWindow?
    ) -> Bool {
        keyboardFocusCoordinator(for: window)?.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId) ?? true
    }

    func syncBonsplitTabShortcutHintEligibility(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.syncBonsplitTabShortcutHintEligibility()
    }

    struct TerminalKeyboardFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
        let ghosttyView: GhosttyNSView
    }

    func terminalKeyboardFocusRequest(for responder: NSResponder?) -> TerminalKeyboardFocusRequest? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalKeyboardFocusRequest(
            workspaceId: workspaceId,
            panelId: panelId,
            ghosttyView: ghosttyView
        )
    }

    func allowsTerminalKeyboardFocus(for responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let request = terminalKeyboardFocusRequest(for: responder) else {
            return true
        }
        return allowsTerminalKeyboardFocus(
            workspaceId: request.workspaceId,
            panelId: request.panelId,
            in: window
        )
    }

    func noteTerminalKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteRightSidebarKeyboardFocusIntent(mode: RightSidebarMode, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteRightSidebarInteraction(mode: mode)
    }

    func syncKeyboardFocusAfterFirstResponderChange(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.syncAfterResponderChange()
    }

    @discardableResult
    func focusRightSidebarInActiveMainWindow(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforeState = context.fileExplorerState ?? fileExplorerState
        dlog(
            "rs.focus.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "visible=\((beforeState?.isVisible ?? false) ? 1 : 0) mode=\(beforeState?.mode.rawValue ?? "nil") " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .rightSidebarFocus)
        }
        let result = context.keyboardFocusCoordinator.focusRightSidebar(
            mode: requestedMode,
            focusFirstItem: focusFirstItem
        )
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.app.end requested=1 result=\(result ? 1 : 0) " +
            "mode=\(requestedMode?.rawValue ?? (context.fileExplorerState?.mode.rawValue ?? "nil")) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

#if DEBUG
    func debugRevealRightSidebarInActiveMainWindow(
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
            setActiveMainWindow(window)
        }

        guard let state = context?.fileExplorerState ?? fileExplorerState else {
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
    func focusFileSearchInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "file.search.focus.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .fileSearchFocus)
        }
        let result = context.keyboardFocusCoordinator.focusFileSearch()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.end result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func performFindShortcutInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "find.shortcut.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .findShortcut)
        }

        let target = context.keyboardFocusCoordinator.findShortcutTarget(
            currentResponder: window?.firstResponder
        )
        let result: Bool
        switch target {
        case .rightSidebarFileSearch:
            result = context.keyboardFocusCoordinator.focusFileSearch()
        case .mainPanelFind:
            result = context.tabManager.startSearch()
        case .none:
            result = false
        }
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.end target=\(target) result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func toggleRightSidebarKeyboardFocusInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.toggle.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .rightSidebarToggle)
        }
        let result = context.keyboardFocusCoordinator.toggleRightSidebarOrTerminalFocus()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.end result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

}
