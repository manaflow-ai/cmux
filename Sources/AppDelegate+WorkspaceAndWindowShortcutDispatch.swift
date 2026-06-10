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



// MARK: - Workspace and window shortcut dispatch
extension AppDelegate {
    // Workspace, window, notification, and tab management shortcuts.
    // Returns nil when no shortcut in this phase matched (dispatch continues).
    func dispatchWorkspaceAndWindowShortcut(
        event: NSEvent,
        commandPaletteTargetWindow: NSWindow?
    ) -> Bool? {
        // Primary UI shortcuts
        if matchConfiguredShortcut(event: event, action: .toggleSidebar) {
            _ = toggleSidebarInActiveMainWindow(preferredWindow: mainWindowForShortcutEvent(event))
            return true
        }

        if matchConfiguredShortcut(event: event, action: .newTab) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            performNewWorkspaceAction(event: event, debugSource: "shortcut.cmdN")
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchConfiguredShortcut(event: event, action: .newWindow) {
            openNewMainWindow(preferredWindow: mainWindowForShortcutEvent(event))
            return true
        }

        // Open Folder: Cmd+O
        // Handled here to prevent AppKit's default NSDocumentController from opening
        // the Documents folder when SwiftUI menu dispatch fails due to focus bugs.
        if matchConfiguredShortcut(event: event, action: .openFolder) {
            showOpenFolderPanel()
            return true
        }

        // Check Show Notifications shortcut
        if matchConfiguredShortcut(event: event, action: .showNotifications) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .openDiffViewer) {
            // Shares the command palette's diff-open path; targets the event window's
            // focused workspace and beeps if it can't be opened (matching the palette).
            let manager = activeTabManagerForCommands(preferredWindow: mainWindowForShortcutEvent(event))
            if !openDiffViewerForFocusedWorkspace(for: manager) {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleRightSidebar) {
            // Escape AppKit's performKeyEquivalent animation context. Without
            // deferring the toggle, NSAnimationContext implicitly animates the
            // layout change.
            let preferredWindow = mainWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            DispatchQueue.main.async { [weak self, weak preferredWindow] in
                _ = self?.toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow)
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusRightSidebar) {
            let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
            let beforeResponder = preferredWindow?.firstResponder
                ?? NSApp.keyWindow?.firstResponder
                ?? NSApp.mainWindow?.firstResponder
            dlog(
                "rs.focus.toggle.shortcut.begin event=\(NSWindow.keyDescription(event)) " +
                "preferred={\(debugWindowToken(preferredWindow))} fr=\(beforeResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            let result = toggleRightSidebarKeyboardFocusInActiveMainWindow(preferredWindow: preferredWindow)
#if DEBUG
            let afterResponder = preferredWindow?.firstResponder
                ?? NSApp.keyWindow?.firstResponder
                ?? NSApp.mainWindow?.firstResponder
            dlog(
                "rs.focus.toggle.shortcut.end result=\(result ? 1 : 0) " +
                "preferred={\(debugWindowToken(preferredWindow))} fr=\(afterResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return true
        }

        if matchConfiguredShortcut(event: event, action: .sendFeedback) {
            guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
                  let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId) else {
                return false
            }
            setActiveMainWindow(targetWindow)
            bringToFront(targetWindow)
            NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
            return true
        }

        // Check Jump to Unread shortcut
        if matchConfiguredShortcut(event: event, action: .jumpToUnread) {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            jumpToLatestUnread()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleUnread) {
            toggleFocusedNotificationUnread(
                preferredWindow: mainWindowForShortcutEvent(event)
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .markOldestUnreadAndJumpNext) {
            markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: mainWindowForShortcutEvent(event)
            )
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchConfiguredShortcut(event: event, action: .triggerFlash) {
            let targetManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            targetManager?.triggerFocusFlash()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            tabManager?.selectPreviousSurface()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleTerminalCopyMode) {
            let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually handled the toggle.
            // Otherwise allow the event to continue through the responder chain.
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .focusTextBoxInput) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.focusFocusedTerminalTextBoxInputOrTerminal() ?? false
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .attachTextBoxFile) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.attachFileToFocusedTerminalTextBoxInput() ?? false
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .sendCtrlFToTerminal) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.sendCtrlFToFocusedTerminal() ?? false
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=sendCtrlFToTerminal handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually received the chord.
            return handled
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchConfiguredShortcut(event: event, action: .nextSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectNextTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .prevSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameWorkspace) {
            return requestRenameWorkspaceViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .groupSelectedWorkspaces) {
            // Only consume the event when grouping actually happened; otherwise
            // fall through so the dispatcher reaches the later
            // `.toggleReactGrab` check (default ⌘⇧G collides with React Grab
            // and grouping returns false when no multi-selection exists).
            if handleGroupSelectedWorkspacesShortcut(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .toggleFocusedWorkspaceGroupCollapsed) {
            // Only consume the event when the toggle actually fired (focused
            // workspace was in a group). Otherwise fall through so a rebinding
            // that shares this chord with another action still works.
            if handleToggleFocusedWorkspaceGroupCollapsedShortcut(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .editWorkspaceDescription) {
#if DEBUG
            cmuxDebugLog(
                "shortcut.editWorkspaceDescription matched target={\(debugWindowToken(commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return requestEditWorkspaceDescriptionViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .closeOtherTabsInPane) {
            if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               targetWindow.identifier?.rawValue == "cmux.settings" {
                targetWindow.performClose(nil)
            } else {
                let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                if let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
                    terminalContext.tabManager.closeOtherTabsInFocusedPaneWithConfirmation()
                } else {
                    tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
                }
            }
            return true
        }

        // The Close Tab shortcut must close the focused panel even if first-responder
        // momentarily lags on a browser NSTextView during split focus transitions.
        if matchConfiguredShortcut(event: event, action: .closeTab) {
            let routedManager = tabManagerForFocusedCloseShortcut(event: event)
            // Browser popup windows primarily intercept the configured Close Tab shortcut
            // in BrowserPopupPanel. This AppDelegate path is a fallback for cases where
            // AppKit routes the event through the global shortcut handler first.
            if let targetWindow = auxiliaryWindowForFocusedCloseShortcut(event: event) {
#if DEBUG
                let route = targetWindow.identifier?.rawValue == "cmux.browser-popup" ? "browserPopup" : "auxWindow"
                cmuxDebugLog("shortcut.closeTab route=\(route)")
#endif
                targetWindow.performClose(nil)
                return true
            } else {
                if let routedManager {
#if DEBUG
                    let selectedWorkspace = routedManager.selectedWorkspace
                    cmuxDebugLog(
                        "shortcut.closeTab route=workspaceModel workspace=\(selectedWorkspace?.id.uuidString.prefix(5) ?? "nil") " +
                        "panel=\(selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                        "selected=\(routedManager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                    )
#endif
                    routedManager.closeCurrentPanelWithConfirmation()
                } else {
#if DEBUG
                    cmuxDebugLog("shortcut.closeTab route=noManager")
#endif
                    return false
                }
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWorkspace) {
            tabManagerForFocusedCloseShortcut(event: event)?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWindow) {
            guard let targetWindow = mainWindowForFocusedCloseShortcut(event: event) else {
                NSSound.beep()
                return true
            }
            _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)
            closeWindowWithConfirmation(targetWindow)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameTab) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteRenameTab(preferredWindow: targetWindow, source: "shortcut.renameTab")
            return true
        }

        // Numeric shortcuts for specific workspaces (9 = last workspace)
        // Always consume the event when the digit matches to prevent Ghostty's
        // goto_tab fallback from creating a new window when the index is out of bounds.
        if let digit = numberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) {
            if let manager = tabManager,
               let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: digit, workspaceCount: manager.tabs.count) {
#if DEBUG
                cmuxDebugLog(
                    "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
                )
#endif
                manager.selectTab(at: targetIndex)
            }
            return true
        }

        // Numeric shortcuts for surfaces within the focused pane (9 = last)
        if let digit = numberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) {
            if digit == 9 {
                tabManager?.selectLastSurface()
            } else {
                tabManager?.selectSurface(at: digit - 1)
            }
            return true
        }

        return nil
    }

}
