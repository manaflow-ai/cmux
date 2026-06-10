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


// MARK: - Browser focus mode and find shortcut ownership
extension AppDelegate {
    func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil,
              browserAddressBarBlurObserver == nil,
              browserWebViewFirstResponderObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
            self.browserAddressBarFocusedPanelId = panelId
            self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            cmuxDebugLog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
            if self.browserAddressBarFocusedPanelId == panelId {
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                cmuxDebugLog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
            }
        }

        browserWebViewFirstResponderObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleBrowserWebViewFirstResponderNotification(notification)
            }
        }
    }

    @MainActor
    private func handleBrowserWebViewFirstResponderNotification(_ notification: Notification) {
        guard let webView = notification.object as? CmuxWebView,
              let panel = browserPanelOwning(webView) else { return }
        let pointerInitiatedKey = BrowserFirstResponderNotificationUserInfoKey.pointerInitiated
        let pointerInitiated = notification.userInfo?[pointerInitiatedKey] as? Bool ?? false

        if let trackedPanelId = browserAddressBarFocusedPanelId,
           trackedPanelId != panel.id,
           let trackedPanel = browserPanel(for: trackedPanelId),
           !shouldPreserveBrowserAddressBarTracking(
               for: trackedPanel,
               trackedPanelMatchesWebView: false,
               pointerInitiatedWebFocus: pointerInitiated,
               in: trackedPanel.webView.window
           ) {
            trackedPanel.endSuppressWebViewFocusForAddressBar()
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(trackedPanelId.uuidString.prefix(8)) " +
                "reason=stale_other_panel_webViewFirstResponder"
            )
#endif
        }

        guard !shouldPreserveBrowserAddressBarTracking(
            for: panel,
            trackedPanelMatchesWebView: panel.webView === webView,
            pointerInitiatedWebFocus: pointerInitiated,
            in: webView.window
        ) else {
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                "reason=skip_preserve_omnibar_handoff pointer=\(pointerInitiated ? 1 : 0)"
            )
#endif
            return
        }
        panel.endSuppressWebViewFocusForAddressBar()
        if browserAddressBarFocusedPanelId == panel.id {
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                "reason=webViewFirstResponder"
            )
#endif
        }
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        return workspaceContainingPanel(panelId: panelId)?.workspace.browserPanel(for: panelId)
    }

    func browserFindBarIsVisible(for webView: CmuxWebView) -> Bool {
        browserPanelOwning(webView)?.searchState != nil
    }

    func isBrowserFocusModeActive(for webView: CmuxWebView) -> Bool {
        browserPanelOwning(webView)?.isBrowserFocusModeActive == true
    }

    func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
        guard let window = panel.webView.window else { return false }
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: panel.webView)
    }

    func browserFocusModePanelForShortcutEvent(_ event: NSEvent) -> BrowserPanel? {
        // Resolve the panel from the web view that owns the responder chain (the
        // same resolver every other browser shortcut uses), not the selected pane:
        // context-menu / web-view-focus entrypoints can focus a WKWebView without
        // updating focusedPanelId. Then confirm that web view actually holds focus,
        // so the bypass stops once focus moves to the sidebar/terminal (where the
        // page can't run the double-Escape exit anyway and cmux shortcuts must work).
        guard let panel = shortcutEventBrowserPanel(event),
              panel.isBrowserFocusModeActive,
              isWebViewFocused(panel) else {
            return nil
        }
        return panel
    }

    func handleBrowserFocusModeKeyEvent(
        _ event: NSEvent,
        webView: CmuxWebView,
        source: String
    ) -> BrowserFocusModeKeyDecision {
        browserPanelOwning(webView)?.handleBrowserFocusModeKeyEvent(event, reason: source) ?? .inactive
    }

    func browserFocusModeContextMenuState(for webView: CmuxWebView) -> (isActive: Bool, canToggle: Bool) {
        guard let panel = browserPanelOwning(webView) else {
            return (isActive: false, canToggle: false)
        }
        return (isActive: panel.isBrowserFocusModeActive, canToggle: panel.canToggleBrowserFocusMode)
    }

    @discardableResult
    func toggleBrowserFocusModeFromContextMenu(for webView: CmuxWebView) -> Bool {
        guard let panel = browserPanelOwning(webView) else { return false }
        return panel.toggleBrowserFocusMode(reason: "contextMenu", focusWebView: true)
    }

    func shouldLetFocusedBrowserOwnFindShortcut(_ event: NSEvent) -> Bool {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let owningWebView = tabManager?.focusedBrowserPanel?.webView as? CmuxWebView
        guard let owningWebView else { return false }
        return shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: shortcutResponder,
            owningWebView: owningWebView
        )
    }

    private func browserPanelOwning(_ webView: CmuxWebView) -> BrowserPanel? {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        if let window = webView.window,
           let context = contextForMainWindow(window) {
            appendCandidate(context.tabManager)
        }
        appendCandidate(tabManager)
        for context in mainWindowContexts.values {
            appendCandidate(context.tabManager)
        }

        for manager in candidateManagers {
            if let panel = browserPanelOwning(webView, in: manager) {
                return panel
            }
        }
        return nil
    }

    private func browserPanelOwning(_ webView: CmuxWebView, in manager: TabManager) -> BrowserPanel? {
        for workspace in manager.tabs {
            if let panel = workspace.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView }) {
                return panel
            }
        }
        return nil
    }

}
