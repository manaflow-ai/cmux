import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    /// Releases every app-owned attachment before a web view is replaced or closed.
    func tearDownWebViewBeforeReplacement(_ oldWebView: WKWebView, reason: String) {
        guard oldWebView === webView else { return }

        if let window = oldWebView.window,
           Self.responderChainContains(window.firstResponder, target: oldWebView) {
            window.makeFirstResponder(nil)
        }

        clearBrowserFocusMode(reason: reason)
        invalidateSearchFocusRequests(reason: reason)
        detachWebViewObservers()
        tearDownReactGrabMessageHandler(for: oldWebView, reason: reason)
        tearDownMediaPlaybackMessageHandler(for: oldWebView)
        tearDownPageRestoration(for: oldWebView)
        designModeController.webViewWillBeRemoved(oldWebView)
        webAuthnCoordinator.tearDown(from: oldWebView)
        oldWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserSSLTrustBypassMessageHandler.name
        )
        sslTrustBypassMessageHandler = nil
        oldWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: MobileBrowserDirtyMessageHandler.name
        )
        mobileBrowserStreamMessageHandler = nil

        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        oldWebView.cmuxBrowserViewportHostView = nil

        if let oldCmuxWebView = oldWebView as? CmuxWebView {
            oldCmuxWebView.cmuxDownloadDelegate = nil
            oldCmuxWebView.clearBrowserDownloadCallbacks()
            oldCmuxWebView.browserViewportModel = nil
            oldCmuxWebView.onBrowserViewportHierarchyChanged = nil
            oldCmuxWebView.onMouseBackButton = nil
            oldCmuxWebView.onMouseForwardButton = nil
            oldCmuxWebView.onContextMenuDownloadStateChanged = nil
            oldCmuxWebView.onSessionDownloadEvent = nil
            oldCmuxWebView.onScreenshotCopied = nil
            oldCmuxWebView.onContextMenuOpenLinkInNewTab = nil
            oldCmuxWebView.contextMenuLinkURLProvider = nil
            oldCmuxWebView.contextMenuCanMoveTabToNewWorkspace = nil
            oldCmuxWebView.contextMenuMoveTabToNewWorkspace = nil
            oldCmuxWebView.onSubframeDownloadIntent = nil
        }
        oldWebView.removeFromSuperview()
    }
}
