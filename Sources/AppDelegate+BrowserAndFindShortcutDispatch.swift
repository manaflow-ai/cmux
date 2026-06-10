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



// MARK: - Browser, surface, and find shortcut dispatch
extension AppDelegate {
    // Surface, browser, markdown, find, and reopen shortcuts.
    // Returns nil when no shortcut in this phase matched (dispatch continues).
    func dispatchBrowserSurfaceAndFindShortcut(event: NSEvent) -> Bool? {
        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchConfiguredShortcut(event: event, action: .newSurface) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchConfiguredShortcut(event: event, action: .openBrowser) {
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusBrowserAddressBar) {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
                return true
            }

            if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .focusHistoryBack) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            if routedManager?.navigateBack() != true {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusHistoryForward) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            if routedManager?.navigateForward() != true {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleBrowserFocusMode) {
            // Reached only when focus mode is off (the active-focus-mode bypass
            // returns earlier), so this enters focus mode for the focused browser.
            // Exit stays double-Escape, which is forwarded to the page first.
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event),
                  focusedBrowserPanel.canToggleBrowserFocusMode else {
                return false
            }
            _ = focusedBrowserPanel.toggleBrowserFocusMode(reason: "configuredShortcut", focusWebView: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserBack) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            focusedBrowserPanel.goBack()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserForward) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            focusedBrowserPanel.goForward()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserReload) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            reloadBrowserPanelForShortcut(focusedBrowserPanel)
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchConfiguredShortcut(event: event, action: .toggleBrowserDeveloperTools) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
            let didHandle = shortcutEventBrowserPanel(event)?.toggleDeveloperTools() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .showBrowserJavaScriptConsole) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
            let didHandle = shortcutEventBrowserPanel(event)?.showDeveloperToolsConsole() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleReactGrab) {
            let didHandle = tabManager?.toggleReactGrabFromCurrentFocus() ?? false
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomIn) {
            return shortcutEventBrowserPanel(event)?.zoomIn() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomOut) {
            return shortcutEventBrowserPanel(event)?.zoomOut() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomReset) {
            return shortcutEventBrowserPanel(event)?.resetZoom() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .markdownZoomIn) {
            return shortcutEventMarkdownPanel(event)?.zoomIn() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .markdownZoomOut) {
            return shortcutEventMarkdownPanel(event)?.zoomOut() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .markdownZoomReset) {
            return shortcutEventMarkdownPanel(event)?.resetZoom() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .findInDirectory) {
            return focusFileSearchInActiveMainWindow(preferredWindow: resolvedShortcutEventWindow(event))
        }

        if matchConfiguredShortcut(event: event, action: .findNext) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.findNext()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .findPrevious) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.findPrevious()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .hideFind) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.hideFind()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .useSelectionForFind) {
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.searchSelection()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .reopenPreviousSession) {
            if !reopenPreviousSession() {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            _ = reopenMostRecentlyClosedItem(preferredTabManager: routedManager)
            return true
        }

        return nil
    }
}
