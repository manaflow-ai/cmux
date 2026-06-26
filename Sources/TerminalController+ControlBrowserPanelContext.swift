import AppKit
import CmuxControlSocket
import CmuxFoundation
import Foundation
import WebKit

/// The live-app half of the v1 browser-panel commands (`open_browser` /
/// `navigate` / `browser_back` / `browser_forward` / `browser_reload` /
/// `get_url` / `focus_webview` / `is_webview_focused`): the coordinator owns
/// the line parsing and the `OK`/`ERROR:` reply shapes; these witnesses run
/// the selected-workspace panel reach, byte-faithful to the legacy bodies
/// (which always targeted the active TabManager's selected workspace).
extension TerminalController: ControlBrowserPanelContext {
    /// The selected workspace's browser panel for a v1 panel id (the shared
    /// guard head of the legacy bodies).
    private func browserPanelV1Panel(panelID: UUID) -> BrowserPanel? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }
        return tab.browserPanel(for: panelID)
    }

    func controlBrowserPanelTabManagerAvailable() -> Bool {
        tabManager != nil
    }

    func controlBrowserPanelAvailabilityEnabled() -> Bool {
        BrowserAvailabilitySettings.isEnabled()
    }

    func controlBrowserPanelOpenURLExternally(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func controlBrowserPanelOpen(url: URL?) -> UUID? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId else {
            return nil
        }
        let focus = Self.socketCommandAllowsInAppFocusMutations()
        return tab.newBrowserSplit(
            from: focusedPanelId,
            orientation: .horizontal,
            url: url,
            focus: focus,
            creationPolicy: .automationPreload
        )?.id
    }

    func controlBrowserPanelNavigate(panelID: UUID, urlString: String) -> Bool {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return false }
        panel.navigateSmart(urlString)
        return true
    }

    func controlBrowserPanelGoBack(panelID: UUID) -> Bool {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return false }
        panel.goBack()
        return true
    }

    func controlBrowserPanelGoForward(panelID: UUID) -> Bool {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return false }
        panel.goForward()
        return true
    }

    func controlBrowserPanelReload(panelID: UUID) -> Bool {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return false }
        panel.reload()
        return true
    }

    func controlBrowserPanelCurrentURLString(panelID: UUID) -> String? {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return nil }
        return panel.currentURL?.absoluteString ?? ""
    }

    func controlBrowserPanelFocusWebView(panelID: UUID) -> ControlBrowserPanelFocusWebViewResolution {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return .panelNotFound }

        // Programmatic WebView focus should win over stale omnibar focus state, especially
        // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
        panel.endSuppressWebViewFocusForAddressBar()
        panel.clearWebViewFocusSuppression()
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelID)

        // Prevent omnibar auto-focus from immediately stealing first responder back.
        panel.suppressOmnibarAutofocus(for: 1.5)

        let webView = panel.webView
        guard let window = webView.window else { return .webViewNotInWindow }
        guard !webView.isHiddenOrHasHiddenAncestor else { return .webViewHidden }

        window.makeFirstResponder(webView)
        guard window.firstResponder?.responderChain(contains: webView) ?? false else {
            return .focusDidNotMove
        }
        // Some focus churn paths (workspace handoff / omnibar blur) can race this call.
        // Reassert on the next runloop if another responder steals focus immediately.
        DispatchQueue.main.async { [weak window, weak webView] in
            guard let window, let webView else { return }
            guard webView.window === window else { return }
            if !(window.firstResponder?.responderChain(contains: webView) ?? false) {
                window.makeFirstResponder(webView)
            }
        }
        return .focused
    }

    func controlBrowserPanelIsWebViewFocused(panelID: UUID) -> ControlBrowserPanelWebViewFocusState {
        guard let panel = browserPanelV1Panel(panelID: panelID) else { return .panelNotFound }
        let webView = panel.webView
        guard let window = webView.window else { return .focused(false) }
        return .focused(window.firstResponder?.responderChain(contains: webView) ?? false)
    }
}
