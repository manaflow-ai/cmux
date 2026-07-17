import AppKit
import WebKit

struct BrowserWebExtensionNavigationConfiguration {
    let contextIdentifier: ObjectIdentifier
    let webViewConfiguration: WKWebViewConfiguration
}

extension BrowserPanel {
    @discardableResult
    func ensureWebExtensionNavigationConfiguration(
        for url: URL,
        allowWebExtensionContext: Bool
    ) -> Bool {
        let targetConfiguration = browserWebExtensionHost?.webViewConfiguration(forNavigatingTo: url)
        let targetContextIdentifier = targetConfiguration?.contextIdentifier
        guard targetContextIdentifier != webExtensionPageContextIdentifier else { return false }
        guard targetContextIdentifier == nil || allowWebExtensionContext else { return false }
        return replaceWebViewForWebExtensionNavigation(
            webViewConfiguration: targetConfiguration?.webViewConfiguration,
            contextIdentifier: targetContextIdentifier,
            targetURL: url
        )
    }

    func navigateFromWebExtension(to url: URL, webViewConfiguration: WKWebViewConfiguration?) {
        var didReplaceWebView = false
        if let webViewConfiguration {
            let contextIdentifier = browserWebExtensionHost?
                .webViewConfiguration(forNavigatingTo: url)?
                .contextIdentifier
            didReplaceWebView = replaceWebViewForWebExtensionNavigation(
                webViewConfiguration: webViewConfiguration,
                contextIdentifier: contextIdentifier,
                targetURL: url
            )
        }
        navigate(to: url, preserveRestoredSessionHistory: didReplaceWebView)
    }

    /// Retries an extension URL restored before its owning context finished loading.
    func retryPendingWebExtensionNavigationIfNeeded() {
        guard webExtensionPageContextIdentifier == nil,
              let url = currentURL,
              let targetConfiguration = browserWebExtensionHost?
                  .webViewConfiguration(forNavigatingTo: url) else {
            return
        }
        let shouldResumeNavigation = shouldRenderWebView
        let didReplaceWebView = replaceWebViewForWebExtensionNavigation(
            webViewConfiguration: targetConfiguration.webViewConfiguration,
            contextIdentifier: targetConfiguration.contextIdentifier,
            targetURL: url
        )
        if shouldResumeNavigation {
            navigate(to: url, preserveRestoredSessionHistory: didReplaceWebView)
        }
    }

    func shouldBlockWebExtensionNavigation(to url: URL, allowWebExtensionContext: Bool) -> Bool {
        guard !allowWebExtensionContext else { return false }
        if browserWebExtensionHost?.webViewConfiguration(forNavigatingTo: url) != nil {
            return true
        }
        return url.scheme?.lowercased() == "webkit-extension"
    }

    func shouldBlockPageInitiatedWebExtensionNavigation(to url: URL) -> Bool {
        let targetContextIdentifier = browserWebExtensionHost?
            .webViewConfiguration(forNavigatingTo: url)?
            .contextIdentifier
        if let targetContextIdentifier,
           targetContextIdentifier == webExtensionPageContextIdentifier {
            return false
        }
        if webExtensionPageContextIdentifier != nil,
           !canOpenPageInitiatedWebExtensionExitURL(url) {
            return true
        }
        return targetContextIdentifier != nil || url.scheme?.lowercased() == "webkit-extension"
    }

    func shouldRoutePageInitiatedWebExtensionNavigationInCurrentTab(to url: URL) -> Bool {
        guard webExtensionPageContextIdentifier != nil,
              canOpenPageInitiatedWebExtensionExitURL(url) else { return false }
        let targetContextIdentifier = browserWebExtensionHost?
            .webViewConfiguration(forNavigatingTo: url)?
            .contextIdentifier
        return targetContextIdentifier != webExtensionPageContextIdentifier
    }

    func allowsWebExtensionContextForPageInitiatedNewTab(to url: URL) -> Bool {
        guard let sourceContextIdentifier = webExtensionPageContextIdentifier,
              let targetContextIdentifier = browserWebExtensionHost?
                .webViewConfiguration(forNavigatingTo: url)?
                .contextIdentifier else {
            return false
        }
        return targetContextIdentifier == sourceContextIdentifier
    }

    /// Opens a request in a sibling browser tab without dropping request metadata.
    func openLinkInNewTab(request: URLRequest, bypassInsecureHTTPHostOnce: String? = nil) {
        guard let seed = browserNewTabNavigationSeed(
            from: request,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else {
            return
        }
        let allowWebExtensionContext = allowsWebExtensionContextForPageInitiatedNewTab(to: seed.url)
#if DEBUG
        cmuxDebugLog(
            "browser.newTab.open.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) url=\(browserNavigationDebugURL(seed.url)) bypass=\(seed.bypassInsecureHTTPHostOnce ?? "nil")"
        )
#endif
        guard BrowserAvailabilitySettings.isEnabled() else {
            _ = NSWorkspace.shared.open(seed.url)
#if DEBUG
            cmuxDebugLog("browser.newTab.open.external panel=\(id.uuidString.prefix(5)) reason=browser_disabled")
#endif
            return
        }
        if Workspace.openDockBrowserLinkInNewTabIfNeeded(
            panel: self,
            seed: seed,
            allowWebExtensionContext: allowWebExtensionContext
        ) {
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
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce,
            allowWebExtensionInitialNavigationConfiguration: allowWebExtensionContext
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

    func canOpenPageInitiatedWebExtensionExitURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme == "http" || scheme == "https" || scheme == "about"
    }
}
