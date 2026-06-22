import AppKit
import CmuxControlSocket
import CmuxSettings
import Foundation
import WebKit

/// The live-app half of the non-JS-evaluating, main-actor `browser.*` commands
/// (`browser.open_split` / `browser.react_grab.toggle` /
/// `browser.devtools.toggle` / `browser.console.show` /
/// `browser.focus_mode.set` / `browser.zoom.set` / `browser.history.clear` /
/// `browser.url.get` / `browser.focus_webview` / `browser.is_webview_focused`):
/// the coordinator owns the param parsing, validation, and `JSONValue` payload
/// shaping; these witnesses perform the `TabManager` / `Workspace` /
/// `BrowserPanel` reach, byte-faithful to the former `v2Browser*` bodies (minus
/// the per-read `v2MainSync` hop, which is a no-op on the main-actor coordinator
/// path). The shared `v2ResolveWindowId` / `v2FocusAllowed` / `v2MaybeFocusWindow`
/// / `v2MaybeSelectWorkspace` / `v2BrowserActionPayload`-feeding resolvers stay
/// on `TerminalController` (also used by the worker-lane and other browser
/// methods).
extension TerminalController: ControlBrowserContext {
    /// The browser-domain twin of `resolveWorkspace(routing:tabManager:)`,
    /// mirroring the former `v2ResolveWorkspace(params:tabManager:)` precedence
    /// on the coordinator-resolved selectors.
    private func browserResolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    func controlBrowserRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// Whether the URL targets the trusted cmux diff viewer (the former
    /// `v2IsDiffViewerURL`, drained here with `v2BrowserOpenSplit` as its only
    /// former caller): the `cmux-diff-viewer://` scheme, or the legacy
    /// `http://127.0.0.1#cmux-diff-viewer` form.
    private func browserIsDiffViewerURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
            return true
        }
        return url.scheme?.lowercased() == "http" &&
            url.host == "127.0.0.1" &&
            url.fragment == "cmux-diff-viewer"
    }

    // MARK: - open_split

    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        rawURLString: String?,
        respectExternalOpenRules: Bool,
        diffViewerToken: String?,
        diffViewerFiles: [JSONValue]?,
        explicitSourceSurfaceID: UUID?,
        requestedFocus: Bool,
        showOmnibar: Bool,
        transparentBackground: Bool,
        bypassRemoteProxyParam: Bool?
    ) -> ControlBrowserOpenSplitResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }

        // Resolve with the same smart logic as browser.navigate (URL, then search
        // fallback) so an unparseable raw string fails loudly instead of silently
        // opening about:blank.
        let url: URL?
        if let urlStr = rawURLString {
            let trimmedURLStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let navigable = resolveBrowserNavigableURL(urlStr) {
                url = navigable
            } else if let parsed = URL(string: trimmedURLStr), parsed.scheme != nil {
                url = parsed
            } else if let search = BrowserSearchSettingsStore().currentConfiguration.searchURL(query: urlStr) {
                url = search
            } else {
                return .unresolvableURL(rawURL: urlStr)
            }
        } else {
            url = nil
        }

        if BrowserAvailabilitySettings.isDisabled() {
            if browserIsDiffViewerURL(url) {
                return .browserDisabled
            }
            return browserDisabledExternalOpenResolution(rawURL: rawURLString, url: url, tabManager: tabManager)
        }

        if let registerError = browserRegisterDiffViewerResolution(
            token: diffViewerToken,
            files: diffViewerFiles,
            url: url
        ) {
            return registerError
        }

        guard let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }

        if let url,
           respectExternalOpenRules,
           BrowserLinkOpenSettings.shouldOpenExternally(url) {
            guard NSWorkspace.shared.open(url) else {
                return .externalOpenRespectedFailed(url: url.absoluteString)
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .externalOpenRespected(windowID: windowId, workspaceID: ws.id, url: url.absoluteString)
        }

        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let sourceSurfaceId = explicitSourceSurfaceID ?? ws.focusedPanelId
        guard let sourceSurfaceId else {
            return .noFocusedSurface
        }
        guard ws.panels[sourceSurfaceId] != nil else {
            return .sourceSurfaceNotFound(surfaceID: sourceSurfaceId)
        }

        let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id
        let focus = v2FocusAllowed(requested: requestedFocus)
        let bypassRemoteProxy = bypassRemoteProxyParam ?? browserIsDiffViewerURL(url)

        var createdSplit = true
        var placementStrategy = "split_right"
        let createdPanel: BrowserPanel?
        if let targetPane = ws.preferredRightSideTargetPane(fromPanelId: sourceSurfaceId) {
            createdPanel = ws.newBrowserSurface(
                inPane: targetPane,
                url: url,
                focus: focus,
                selectWhenNotFocused: true,
                creationPolicy: .automationPreload,
                omnibarVisible: showOmnibar,
                transparentBackground: transparentBackground,
                bypassRemoteProxy: bypassRemoteProxy
            )
            createdSplit = false
            placementStrategy = "reuse_right_sibling"
        } else {
            createdPanel = ws.newBrowserSplit(
                from: sourceSurfaceId,
                orientation: .horizontal,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload,
                omnibarVisible: showOmnibar,
                transparentBackground: transparentBackground,
                bypassRemoteProxy: bypassRemoteProxy
            )
        }

        guard let browserPanelId = createdPanel?.id else {
            return .createFailed
        }

        let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .created(ControlBrowserOpenSplitSuccess(
            browserSurfaceID: browserPanelId,
            sourceSurfaceID: sourceSurfaceId,
            sourcePaneID: sourcePaneUUID,
            targetPaneID: targetPaneUUID,
            workspaceID: ws.id,
            windowID: windowId,
            createdSplit: createdSplit,
            placementStrategy: placementStrategy,
            omnibarVisible: createdPanel?.isOmnibarVisible ?? showOmnibar,
            transparentBackground: transparentBackground,
            bypassRemoteProxy: bypassRemoteProxy
        ))
    }

    /// The disabled-browser external-open fallback, the typed twin of
    /// `v2BrowserDisabledExternalOpenResult` (which stays on `TerminalController`
    /// for the worker-lane `browser.navigate`-family callers).
    private func browserDisabledExternalOpenResolution(
        rawURL: String?,
        url: URL?,
        tabManager: TabManager?
    ) -> ControlBrowserOpenSplitResolution {
        if let rawURL, url == nil {
            return .disabledExternalInvalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .disabledExternalNoURL
        }
        guard NSWorkspace.shared.open(url) else {
            return .disabledExternalOpenFailed(url: url.absoluteString)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .disabledExternalOpened(windowID: windowId, url: url.absoluteString)
    }

    /// Registers the trusted diff-viewer allowlist when the URL uses that
    /// scheme, the typed twin of `v2RegisterDiffViewerURLIfNeeded`: returns a
    /// resolution only on failure, `nil` when nothing to register or success.
    private func browserRegisterDiffViewerResolution(
        token: String?,
        files: [JSONValue]?,
        url: URL?
    ) -> ControlBrowserOpenSplitResolution? {
        guard let url,
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return nil
        }
        let rawFiles = (files?.map(\.foundationObject)).flatMap { $0 as? [[String: Any]] }
        guard let token,
              token == url.host,
              let rawFiles,
              !rawFiles.isEmpty,
              rawFiles.count <= CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles else {
            return .invalidDiffViewerAllowlist(
                message: "Missing or invalid trusted diff viewer allowlist",
                details: nil
            )
        }

        let registeredFiles = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard registeredFiles.count == rawFiles.count else {
            return .invalidDiffViewerAllowlist(message: "Invalid trusted diff viewer allowlist", details: nil)
        }

        do {
            try CmuxDiffViewerURLSchemeHandler.shared.register(token: token, files: registeredFiles)
            return nil
        } catch {
            return .invalidDiffViewerAllowlist(
                message: "Invalid trusted diff viewer allowlist",
                details: error.localizedDescription
            )
        }
    }

    // MARK: - react_grab.toggle

    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserActionResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .noBrowserSurface
        }
        guard let actedBrowserId = tabManager.toggleReactGrab(
            in: ws,
            browserSurfaceId: browserSurfaceID,
            returnTerminalSurfaceId: returnSurfaceID
        ) else { return .noBrowserSurface }
        return .acted(ControlBrowserActedSurface(
            workspaceID: ws.id,
            surfaceID: actedBrowserId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            flag: true
        ))
    }

    // MARK: - devtools.toggle

    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let target = browserResolvePanelForFocusedAction(
                  workspace: ws,
                  explicitSurfaceID: explicitSurfaceID,
                  surfaceWasSupplied: surfaceWasSupplied
              ) else {
            return .noBrowserSurface
        }
        let handled = target.panel.toggleDeveloperTools()
        return .acted(ControlBrowserActedSurface(
            workspaceID: ws.id,
            surfaceID: target.surfaceId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            flag: handled
        ))
    }

    // MARK: - console.show

    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let target = browserResolvePanelForFocusedAction(
                  workspace: ws,
                  explicitSurfaceID: explicitSurfaceID,
                  surfaceWasSupplied: surfaceWasSupplied
              ) else {
            return .noBrowserSurface
        }
        let handled = target.panel.showDeveloperToolsConsole()
        return .acted(ControlBrowserActedSurface(
            workspaceID: ws.id,
            surfaceID: target.surfaceId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            flag: handled
        ))
    }

    // MARK: - focus_mode.set

    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        intent: ControlBrowserFocusModeIntent
    ) -> ControlBrowserActionResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let target = browserResolvePanelForFocusedAction(
                  workspace: ws,
                  explicitSurfaceID: explicitSurfaceID,
                  surfaceWasSupplied: surfaceWasSupplied
              ) else {
            return .noBrowserSurface
        }
        // Entering browser focus mode requires the target browser to be the focused, on-screen
        // panel (the GUI shortcut already runs from inside it). When the CLI targets a browser
        // that is not focused, focus it first so "enter" actually engages instead of no-opping.
        // Focusing the panel makes the render/visibility/modal-host preconditions of
        // canEnterBrowserFocusMode true, so those are not a reason to withhold focus. An open
        // find bar (searchState) is the one precondition focusing does NOT satisfy: entry will
        // fail, so don't steal foreground focus or collapse a split-zoom for an action that
        // cannot engage.
        let willActivate = intent == .enter
            || (intent == .toggle && !target.panel.isBrowserFocusModeActive)
        if willActivate, target.panel.searchState == nil, ws.focusedPanelId != target.surfaceId {
            ws.clearSplitZoom()
            ws.focusPanel(target.surfaceId)
        }
        let handled: Bool
        switch intent {
        case .enter:
            handled = target.panel.setBrowserFocusModeActive(true, reason: "cli.focusMode", focusWebView: true)
        case .exit:
            handled = target.panel.setBrowserFocusModeActive(false, reason: "cli.focusMode", focusWebView: false)
        case .toggle:
            handled = target.panel.toggleBrowserFocusMode(reason: "cli.focusMode", focusWebView: true)
        }
        return .acted(ControlBrowserActedSurface(
            workspaceID: ws.id,
            surfaceID: target.surfaceId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            flag: handled
        ))
    }

    // MARK: - zoom.set

    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserActionResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let target = browserResolvePanelForFocusedAction(
                  workspace: ws,
                  explicitSurfaceID: explicitSurfaceID,
                  surfaceWasSupplied: surfaceWasSupplied
              ) else {
            return .noBrowserSurface
        }
        let handled: Bool
        switch direction {
        case .zoomIn: handled = target.panel.zoomIn()
        case .zoomOut: handled = target.panel.zoomOut()
        case .reset: handled = target.panel.resetZoom()
        }
        return .acted(ControlBrowserActedSurface(
            workspaceID: ws.id,
            surfaceID: target.surfaceId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            flag: handled
        ))
    }

    // MARK: - history.clear

    func controlBrowserClearDefaultHistory() {
        BrowserHistoryStore.shared.clearHistory()
    }

    // MARK: - url.get

    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFound
        }
        // A never-navigated surface reports about:blank (matching JS location.href)
        // instead of an empty string, so agents can tell "blank page" from "no data".
        let urlString = browserPanel.currentURL?.absoluteString
            ?? browserPanel.webView.url?.absoluteString
            ?? "about:blank"
        return .resolved(workspaceID: ws.id, url: urlString)
    }

    // MARK: - focus_webview

    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFound
        }

        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }

        // Prevent omnibar auto-focus from immediately stealing first responder back.
        browserPanel.suppressOmnibarAutofocus(for: 1.0)

        let webView = browserPanel.webView
        guard let window = webView.window else {
            return .webViewNotInWindow
        }
        guard !webView.isHiddenOrHasHiddenAncestor else {
            return .webViewHidden
        }

        window.makeFirstResponder(webView)
        if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
            return .focused
        }
        return .focusDidNotMove
    }

    // MARK: - is_webview_focused

    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserIsWebViewFocusedResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = browserResolveWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return ControlBrowserIsWebViewFocusedResolution(focused: false)
        }
        let webView = browserPanel.webView
        guard let window = webView.window,
              let fr = window.firstResponder as? NSView else {
            return ControlBrowserIsWebViewFocusedResolution(focused: false)
        }
        return ControlBrowserIsWebViewFocusedResolution(focused: fr.isDescendant(of: webView))
    }

    /// The focused-or-named browser-panel resolver for the action commands, the
    /// twin of `v2ResolveBrowserPanelForFocusedAction` operating on the
    /// coordinator-resolved `surface_id` presence + value (the legacy
    /// `v2HasNonNullParam` / `v2UUID` reads). Kept here (not on
    /// `TerminalController`) because no worker-lane caller needs it.
    private func browserResolvePanelForFocusedAction(
        workspace: Workspace,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> (panel: BrowserPanel, surfaceId: UUID)? {
        // An explicit surface is authoritative: if surface_id is SUPPLIED (even as a stale,
        // unresolvable, or empty handle) it must resolve to a browser in this workspace, else nil.
        // Only a genuinely ABSENT surface_id falls back to the focused/sole browser.
        if surfaceWasSupplied {
            guard let sid = explicitSurfaceID,
                  let panel = workspace.browserPanel(for: sid) else { return nil }
            return (panel, sid)
        }
        if let focusedId = workspace.focusedPanelId, let panel = workspace.browserPanel(for: focusedId) {
            return (panel, focusedId)
        }
        let browsers: [(UUID, BrowserPanel)] = workspace.panels.values.compactMap { panel in
            (panel as? BrowserPanel).map { (panel.id, $0) }
        }
        if browsers.count == 1 { return (browsers[0].1, browsers[0].0) }
        return nil
    }

    // MARK: - network.route / unroute / requests (unsupported-attempt log)

    func controlBrowserRecordUnsupportedNetworkRequest(
        surfaceID: UUID,
        action: String,
        params: [String: JSONValue]
    ) {
        let foundationParams = JSONValue.object(params).foundationObject
        browserAutomation.recordUnsupportedNetworkRequest(
            surfaceId: surfaceID,
            request: ["action": action, "params": foundationParams]
        )
    }

    func controlBrowserUnsupportedNetworkRequests(surfaceID: UUID) -> [JSONValue] {
        browserAutomation.unsupportedNetworkRequests(surfaceId: surfaceID).compactMap {
            JSONValue(foundationObject: $0)
        }
    }
}
