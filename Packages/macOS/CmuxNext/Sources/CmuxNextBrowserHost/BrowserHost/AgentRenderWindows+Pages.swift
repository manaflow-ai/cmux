package import CmuxNextBrowser
import CmuxNextBrowserAutomation
package import WebKit

/// Background browser use (user 2026-11-05: an agent drives tabs that are not visible or in focus).
/// One path for every agent entry point: `cmux browser` and MCP (`browser.page.*`), the REPL's
/// WebKit driver and its Chromium relay.
extension AgentRenderWindows {
    /// Before an agent acts on a live page no window shows (a background tab of a pane, a tab of a
    /// parked workspace, one never shown, one just woken from hibernation, a WebKit tab of a minimized
    /// or fully covered window), its view moves into its
    /// off-screen render window. Hidden, WebKit runs no animation frame, fires timers once a second
    /// and takes no native input (no window); Chromium draws no frame. Nothing shows and focus does
    /// not move. A Chromium tab whose pane shows another tab first moves to a Chromium window of its
    /// own, so the pane keeps its page (``CEFAgentRelay/needsRenderWindow``).
    ///
    /// - Parameter needsAScreen: The call is a wheel: a page in a covered window on a screen stays
    ///   there (WebKit runs a trusted native wheel only in a window on a screen).
    /// - Returns: the WebKit page's web view when it moved (the caller waits for WebKit's activity
    ///   state before input), else nil.
    @discardableResult
    package func keepRendering(tabID: String, entry: BrowserEntry, needsAScreen: Bool = false) -> WKWebView? {
        let view = entry.chrome ?? entry.tab.contentView
        // A wheel stays in a shown window on a screen (`BrowserPageOperation.needsAScreen`).
        if needsAScreen, view.window?.screen != nil, !view.isHiddenOrHasHiddenAncestor { return nil }
        switch entry.tab {
        case let page as WebKitTab:
            return keepRendering(tabID: tabID, chrome: view, webView: page.webView) ? page.webView : nil
        case let page as CEFTab where page.agentRelay.needsRenderWindow:
            _ = keepRendering(tabID: tabID, chrome: view, webView: nil)
            return nil
        default:
            return nil
        }
    }

    /// ``keepRendering(tabID:entry:)``, then, for a WebKit page that moved, the wait until WebKit
    /// sent the page its window, visibility and focus state.
    /// - Parameter needsAScreen: The call is a wheel: a page in a covered window on a screen stays there.
    package func render(tabID: String, entry: BrowserEntry, needsAScreen: Bool = false) async {
        guard let webView = keepRendering(tabID: tabID, entry: entry, needsAScreen: needsAScreen) else { return }
        await privateCalls.afterActivityStateUpdate(webView)
    }
}
