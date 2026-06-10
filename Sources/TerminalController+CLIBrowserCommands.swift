import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - CLI browser commands
extension TerminalController {
    func openExternallyWhenBrowserDisabled(rawURL: String? = nil, url: URL?) -> String {
        if let rawURL, url == nil {
            return "ERROR: Invalid URL \(rawURL)"
        }
        guard let url else { return "ERROR: cmux browser is disabled" }

        let opened: Bool
        if Thread.isMainThread {
            opened = NSWorkspace.shared.open(url)
        } else {
            var didOpen = false
            DispatchQueue.main.sync {
                didOpen = NSWorkspace.shared.open(url)
            }
            opened = didOpen
        }

        return opened ? "OK external_browser_disabled \(url.absoluteString)" : "ERROR: Failed to open URL externally"
    }

    // MARK: - Browser Panel Commands

    func openBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: trimmed)
        guard BrowserAvailabilitySettings.isEnabled() else {
            return openExternallyWhenBrowserDisabled(rawURL: trimmed.isEmpty ? nil : trimmed, url: url)
        }

        var result = "ERROR: Failed to create browser panel"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            if let browserPanelId = tab.newBrowserSplit(
                from: focusedPanelId,
                orientation: .horizontal,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload
            )?.id {
                result = "OK \(browserPanelId.uuidString)"
            }
        }
        return result
    }

    func navigateBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: navigate <panel_id> <url>" }

        let panelArg = parts[0]
        let urlStr = parts[1]

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.navigateSmart(urlStr)
            result = "OK"
        }
        return result
    }

    func browserBack(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_back <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goBack()
            result = "OK"
        }
        return result
    }

    func browserForward(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_forward <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goForward()
            result = "OK"
        }
        return result
    }

    func browserReload(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_reload <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.reload()
            result = "OK"
        }
        return result
    }

    func getUrl(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: get_url <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            result = browserPanel.currentURL?.absoluteString ?? ""
        }
        return result
    }

    func focusWebView(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: focus_webview <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            // Programmatic WebView focus should win over stale omnibar focus state, especially
            // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
            browserPanel.endSuppressWebViewFocusForAddressBar()
            browserPanel.clearWebViewFocusSuppression()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.5)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "ERROR: WebView is not in a window"
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = "ERROR: WebView is hidden"
                return
            }

            window.makeFirstResponder(webView)
            if Self.responderChainContains(window.firstResponder, target: webView) {
                // Some focus churn paths (workspace handoff / omnibar blur) can race this call.
                // Reassert on the next runloop if another responder steals focus immediately.
                DispatchQueue.main.async { [weak window, weak webView] in
                    guard let window, let webView else { return }
                    guard webView.window === window else { return }
                    if !Self.responderChainContains(window.firstResponder, target: webView) {
                        window.makeFirstResponder(webView)
                    }
                }
                result = "OK"
            } else {
                result = "ERROR: Focus did not move into web view"
            }
        }
        return result
    }

    func isWebViewFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_webview_focused <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "false"
                return
            }
            result = Self.responderChainContains(window.firstResponder, target: webView) ? "true" : "false"
        }
        return result
    }

    // MARK: - Bonsplit Pane Commands

}
