import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Page actions
extension BrowserPanel {
    @discardableResult
    func applyMuteState(_ muted: Bool? = nil, to webView: WKWebView, reason: String) -> Bool {
        let targetMuted = muted ?? isMuted
        let applied = webView.cmuxSetPageAudioMuted(targetMuted)
#if DEBUG
        if !applied {
            cmuxDebugLog(
                "browser.audioMute.applyUnavailable panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) muted=\(targetMuted ? 1 : 0)"
            )
        }
#endif
        return applied
    }

    private func cancelInFlightNavigationBeforeHistoryTraversal() {
        guard webView.isLoading || isMainFrameProvisionalNavigationActive else { return }
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let applied = applyMuteState(muted, to: webView, reason: "setMuted")
        if applied, isMuted != muted {
            isMuted = muted
        }
        return applied
    }

    @discardableResult
    func toggleMute() -> Bool {
        setMuted(!isMuted)
    }

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goBack")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if (isLiveSessionHistoryAlignedWithRestoredCurrent || !nativeCanGoBack),
               let targetURL = restoredBackHistoryStack.popLast() {
                if let current = resolvedCurrentSessionHistoryURL() {
                    restoredForwardHistoryStack.append(current)
                }
                restoredHistoryCurrentURL = targetURL
                refreshNavigationAvailability()
                navigateWithoutInsecureHTTPPrompt(
                    to: targetURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
                return
            }

            if nativeCanGoBack {
                webView.goBack()
                return
            }

            refreshNavigationAvailability()
            return
        }

        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        reactivateDiscardedWebViewWithoutNavigation(reason: "goForward")
        cancelInFlightNavigationBeforeHistoryTraversal()
        if usesRestoredSessionHistory {
            realignRestoredSessionHistoryToLiveCurrentIfPossible()

            if nativeCanGoForward {
                webView.goForward()
                return
            }

            guard let targetURL = restoredForwardHistoryStack.popLast() else {
                refreshNavigationAvailability()
                return
            }
            if let current = resolvedCurrentSessionHistoryURL() {
                restoredBackHistoryStack.append(current)
            }
            restoredHistoryCurrentURL = targetURL
            refreshNavigationAvailability()
            navigateWithoutInsecureHTTPPrompt(
                to: targetURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true
            )
            return
        }

        webView.goForward()
    }

    /// Open a link in a new browser surface in the same pane
    func openLinkInNewTab(url: URL, bypassInsecureHTTPHostOnce: String? = nil) {
        openLinkInNewTab(
            request: URLRequest(url: url),
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
    }

    /// Opens a request in a sibling browser tab without dropping request metadata.
    func openLinkInNewTab(request: URLRequest, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let seed = browserNewTabNavigationSeed(
            from: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(browserNavigationDebugURL(seed.url)) " +
            "bypass=\(seed.bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard BrowserAvailabilitySettings.isEnabled() else {
            _ = NSWorkspace.shared.open(seed.url)
#if DEBUG
            cmuxDebugLog("browser.newTab.open.external panel=\(id.uuidString.prefix(5)) reason=browser_disabled")
#endif
            return
        }
        guard let app = AppDelegate.shared else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=missingAppDelegate")
#endif
            return
        }
        guard let workspace = app.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=workspaceMissing")
#endif
            return
        }
        guard let paneId = workspace.paneId(forPanelId: id) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=paneMissing")
#endif
            return
        }
        guard let _ = workspace.newBrowserSurface(
            inPane: paneId,
            url: seed.url,
            initialRequest: seed.initialRequest,
            focus: true,
            preferredProfileID: profileID,
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce
        ) else {
#if DEBUG
            cmuxDebugLog("browser.newTab.open.abort panel=\(id.uuidString.prefix(5)) reason=newPanelFailed")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.done panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5))"
        )
#endif
    }

    var currentURLForTabDuplication: URL? {
        resolvedCurrentSessionHistoryURL()
            ?? Self.remoteProxyDisplayURL(for: webView.url)
            ?? currentURL
    }

    var bypassesRemoteWorkspaceProxyForTabDuplication: Bool {
        bypassesRemoteWorkspaceProxy
    }

    /// Reload the current page
    func reload() {
        if recoverTerminatedWebContent(reason: "reload") {
            return
        }
        if restoreDiscardedWebViewIfNeeded(reason: "reload") {
            return
        }
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        if Self.serializableSessionHistoryURLString(Self.remoteProxyDisplayURL(for: webView.url)) == nil {
            let fallbackURL = resolvedCurrentSessionHistoryURL()
                ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)

            if let fallbackURL,
               Self.serializableSessionHistoryURLString(fallbackURL) != nil {
                navigateWithoutInsecureHTTPPrompt(
                    to: fallbackURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: usesRestoredSessionHistory
                )
                return
            }
        }
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
    }

    @discardableResult
    func zoomIn() -> Bool {
        applyPageZoom(webView.pageZoom + pageZoomStep)
    }

    @discardableResult
    func zoomOut() -> Bool {
        applyPageZoom(webView.pageZoom - pageZoomStep)
    }

    @discardableResult
    func resetZoom() -> Bool {
        applyPageZoom(1.0)
    }

    func currentPageZoomFactor() -> CGFloat {
        webView.pageZoom
    }

    @discardableResult
    func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, pageZoom))
        return applyPageZoom(clamped)
    }

    @discardableResult
    private func applyPageZoom(_ candidate: CGFloat) -> Bool {
        let clamped = max(minPageZoom, min(maxPageZoom, candidate))
        if abs(webView.pageZoom - clamped) < 0.0001 {
            return false
        }
        webView.pageZoom = clamped
        return true
    }

}
