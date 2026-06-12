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


// MARK: - Shortcut event window and tab manager routing
extension AppDelegate {
    func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.window"),
           let window = resolvedWindow(for: context) {
            return window
        }
        if let window = resolvedShortcutEventWindow(event),
           isMainTerminalWindow(window) {
            return window
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    func mainWindowForFocusedCloseShortcut(event: NSEvent) -> NSWindow? {
        // Close shortcuts are focused-window commands. Some AppKit key-equivalent
        // paths can preserve stale event window metadata after a new window becomes
        // key, so prefer the actual focused window before falling back to event data.
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return mainWindowForShortcutEvent(event)
    }

    func tabManagerForFocusedCloseShortcut(event: NSEvent) -> TabManager? {
        if let targetWindow = mainWindowForFocusedCloseShortcut(event: event) {
            return synchronizeActiveMainWindowContext(preferredWindow: targetWindow)
        }
        return preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
    }

    func auxiliaryWindowForFocusedCloseShortcut(event: NSEvent) -> NSWindow? {
        [
            NSApp.keyWindow,
            NSApp.mainWindow,
            resolvedShortcutEventWindow(event),
        ]
        .compactMap { $0 }
        .first { cmuxWindowShouldOwnCloseShortcut($0) }
    }

    struct FocusedTerminalShortcutContext {
        let tabManager: TabManager
        let workspaceId: UUID
        let panelId: UUID
    }

    private func resolveShortcutTabManager(for tabId: UUID, preferredWindow: NSWindow? = nil) -> TabManager? {
        if let manager = tabManagerFor(tabId: tabId) {
            return manager
        }
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow),
           context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           activeManager.tabs.contains(where: { $0.id == tabId }) {
            return activeManager
        }
        return nil
    }

    func focusedTerminalShortcutContext(preferredWindow: NSWindow? = nil) -> FocusedTerminalShortcutContext? {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let responder = targetWindow?.firstResponder
            ?? NSApp.keyWindow?.firstResponder
            ?? NSApp.mainWindow?.firstResponder
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id,
              let manager = resolveShortcutTabManager(for: workspaceId, preferredWindow: targetWindow) else {
            return nil
        }
        return FocusedTerminalShortcutContext(
            tabManager: manager,
            workspaceId: workspaceId,
            panelId: panelId
        )
    }

    func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    func preferredRegisteredMainWindowContext(preferredWindow: NSWindow? = nil) -> MainWindowContext? {
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    func currentKeyboardShortcutEvent() -> NSEvent? {
        guard let event = NSApp.currentEvent,
              event.type == .keyDown || event.type == .keyUp else {
            return nil
        }
        return event
    }

    func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               cmuxWindowShouldOwnCloseShortcut(eventWindow) {
                // Auxiliary cmux windows do not own a terminal tab manager. Let them fall back
                // to the active main terminal window so app shortcuts like Close Tab still route.
            } else {
#if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: "shortcut.routing",
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
#endif
                return nil
            }
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let activeManager = tabManager,
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            focusLog.append(
                "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
            )
#endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

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
        focusLog.append(
            "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
        )
#endif
        return true
    }

    func resolvedMainWindowSource(_ window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        if isMainTerminalWindow(window) {
            return window
        }
        if let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window) {
            return resolvedWindow(for: context)
        }
        return nil
    }

}
