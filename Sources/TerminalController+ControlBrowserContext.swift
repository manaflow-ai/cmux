import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import WebKit

/// The live-app half of the v2 browser navigation/panel domain
/// (`browser.open_split`, `browser.navigate`, history nav, the
/// focused-browser actions, `browser.url.get` / `browser.focus_webview` /
/// `browser.is_webview_focused`, `browser.history.clear`, and
/// `browser.import.dialog`): the coordinator owns param parsing, error
/// shaping, and payload building; these witnesses run the irreducibly
/// app-coupled work, byte-faithful to the legacy `v2Browser*` bodies. The
/// cookies/storage/tabs/state half lives in `+ControlBrowserContext2.swift`
/// (file-length budget).
extension TerminalController: ControlBrowserContext {
    // MARK: - Availability / diff viewer

    func controlBrowserIsAvailabilityDisabled() -> Bool {
        BrowserAvailabilitySettings.isDisabled()
    }

    func controlBrowserIsAvailabilityEnabled() -> Bool {
        BrowserAvailabilitySettings.isEnabled()
    }

    /// The legacy `v2IsDiffViewerURL`.
    private func browserIsDiffViewerURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
            return true
        }
        return url.scheme?.lowercased() == "http" &&
            url.host == "127.0.0.1" &&
            url.fragment == "cmux-diff-viewer"
    }

    func controlBrowserIsDiffViewerURL(_ urlString: String?) -> Bool {
        browserIsDiffViewerURL(urlString.flatMap { URL(string: $0) })
    }

    func controlBrowserDisabledExternalOpen(
        rawURL: String?,
        routing: ControlRoutingSelectors
    ) -> ControlSurfaceBrowserDisabledOutcome {
        let url = rawURL.flatMap { URL(string: $0) }
        if let rawURL, url == nil {
            return .invalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .noURL
        }
        guard NSWorkspace.shared.open(url) else {
            return .externalOpenFailed(url: url.absoluteString)
        }
        let windowId = v2ResolveWindowId(tabManager: resolveTabManager(routing: routing))
        return .openedExternally(windowID: windowId, url: url.absoluteString)
    }

    func controlBrowserRegisterDiffViewer(
        urlString: String?,
        token: String?,
        files: JSONValue?
    ) -> ControlBrowserDiffViewerRegistration {
        guard let url = urlString.flatMap({ URL(string: $0) }),
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return .notApplicable
        }
        guard let token,
              token == url.host,
              let rawFiles = files?.foundationObject as? [[String: Any]],
              !rawFiles.isEmpty,
              rawFiles.count <= CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles else {
            return .missingOrInvalidAllowlist
        }

        let registeredFiles = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard registeredFiles.count == rawFiles.count else {
            return .invalidAllowlist
        }

        do {
            try CmuxDiffViewerURLSchemeHandler.shared.register(token: token, files: registeredFiles)
            return .registered
        } catch {
            return .invalidAllowlistDetails(error.localizedDescription)
        }
    }

    // MARK: - open_split

    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlBrowserOpenSplitInputs
    ) -> ControlBrowserOpenSplitResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let url = inputs.urlString.flatMap { URL(string: $0) }
        if let url,
           inputs.respectExternalOpenRules,
           BrowserLinkOpenSettings.shouldOpenExternally(url) {
            guard NSWorkspace.shared.open(url) else {
                return .externalOpenFailed(url: url.absoluteString)
            }
            return .openedExternally(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                url: url.absoluteString
            )
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let sourceSurfaceId = inputs.sourceSurfaceID ?? ws.focusedPanelId
        guard let sourceSurfaceId else {
            return .noFocusedSurface
        }
        guard ws.panels[sourceSurfaceId] != nil else {
            return .sourceSurfaceNotFound(surfaceID: sourceSurfaceId)
        }

        let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id
        let focus = v2FocusAllowed(requested: inputs.focusRequested)
        let omnibarVisible = inputs.showOmnibar
        let transparentBackground = inputs.transparentBackground
        let bypassRemoteProxy = inputs.bypassRemoteProxy ?? browserIsDiffViewerURL(url)

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
                omnibarVisible: omnibarVisible,
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
                omnibarVisible: omnibarVisible,
                transparentBackground: transparentBackground,
                bypassRemoteProxy: bypassRemoteProxy
            )
        }

        guard let browserPanelId = createdPanel?.id else {
            return .createFailed
        }

        let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
        return .created(ControlBrowserOpenSplitResolution.Snapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: targetPaneUUID,
            surfaceID: browserPanelId,
            sourceSurfaceID: sourceSurfaceId,
            sourcePaneID: sourcePaneUUID,
            createdSplit: createdSplit,
            placementStrategy: placementStrategy,
            showOmnibar: createdPanel?.isOmnibarVisible ?? omnibarVisible,
            transparentBackground: transparentBackground,
            bypassRemoteProxy: bypassRemoteProxy
        ))
    }

    // MARK: - navigate / history nav

    func controlBrowserNavigate(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        urlString: String
    ) -> ControlBrowserNavResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFoundOrNotBrowser
        }
        browserPanel.navigateSmart(urlString)
        return .ok(workspaceID: ws.id, windowID: v2ResolveWindowId(tabManager: tabManager))
    }

    func controlBrowserNavAction(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        action: ControlBrowserNavAction
    ) -> ControlBrowserNavResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFoundOrNotBrowser
        }
        switch action {
        case .back:
            browserPanel.goBack()
        case .forward:
            browserPanel.goForward()
        case .reload:
            browserPanel.reload()
        }
        return .ok(workspaceID: ws.id, windowID: v2ResolveWindowId(tabManager: tabManager))
    }

    // MARK: - focused-browser actions

    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserReactGrabResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let actedBrowserId = tabManager.toggleReactGrab(
                in: ws,
                browserSurfaceId: browserSurfaceID,
                returnTerminalSurfaceId: returnSurfaceID
              ) else {
            return .notFound
        }
        return .toggled(
            workspaceID: ws.id,
            surfaceID: actedBrowserId,
            windowID: v2ResolveWindowId(tabManager: tabManager)
        )
    }

    /// Resolves the browser panel a focused-browser action should target (the
    /// legacy `v2ResolveBrowserPanelForFocusedAction`): a SUPPLIED `surface_id`
    /// is authoritative (even when unresolvable), a genuinely absent one falls
    /// back to the focused browser, then the workspace's sole browser.
    private func browserFocusedActionPanel(
        workspace: Workspace,
        target: ControlBrowserFocusedActionTarget
    ) -> (panel: BrowserPanel, surfaceId: UUID)? {
        if target.hasSurfaceParam {
            guard let sid = target.surfaceID,
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

    /// The shared resolution head of the focused-browser actions.
    private func browserFocusedAction(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        perform: (Workspace, BrowserPanel, UUID) -> Bool
    ) -> ControlBrowserHandledResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let resolved = browserFocusedActionPanel(workspace: ws, target: target) else {
            return .notFound
        }
        let handled = perform(ws, resolved.panel, resolved.surfaceId)
        return .acted(
            workspaceID: ws.id,
            surfaceID: resolved.surfaceId,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            handled: handled
        )
    }

    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution {
        browserFocusedAction(routing: routing, target: target) { _, panel, _ in
            panel.toggleDeveloperTools()
        }
    }

    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution {
        browserFocusedAction(routing: routing, target: target) { _, panel, _ in
            panel.showDeveloperToolsConsole()
        }
    }

    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        action: ControlBrowserFocusModeAction
    ) -> ControlBrowserHandledResolution {
        browserFocusedAction(routing: routing, target: target) { ws, panel, surfaceId in
            // Entering browser focus mode requires the target browser to be the focused, on-screen
            // panel (the GUI shortcut already runs from inside it). When the CLI targets a browser
            // that is not focused, focus it first so "enter" actually engages instead of no-opping.
            let willActivate: Bool
            switch action {
            case .activate:
                willActivate = true
            case .deactivate:
                willActivate = false
            case .toggle:
                willActivate = !panel.isBrowserFocusModeActive
            }
            if willActivate, ws.focusedPanelId != surfaceId {
                ws.clearSplitZoom()
                ws.focusPanel(surfaceId)
            }
            switch action {
            case .activate:
                return panel.setBrowserFocusModeActive(true, reason: "cli.focusMode", focusWebView: true)
            case .deactivate:
                return panel.setBrowserFocusModeActive(false, reason: "cli.focusMode", focusWebView: false)
            case .toggle:
                return panel.toggleBrowserFocusMode(reason: "cli.focusMode", focusWebView: true)
            }
        }
    }

    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserHandledResolution {
        browserFocusedAction(routing: routing, target: target) { _, panel, _ in
            switch direction {
            case .zoomIn: return panel.zoomIn()
            case .zoomOut: return panel.zoomOut()
            case .reset: return panel.resetZoom()
            }
        }
    }

    // MARK: - history / url / web-view focus

    func controlBrowserClearDefaultProfileHistory() {
        // Mirrors the View menu's "Clear Browser History", which clears the default profile's
        // history store (BrowserHistoryStore.shared). Per-profile history stores are NOT touched.
        BrowserHistoryStore.shared.clearHistory()
    }

    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFoundOrNotBrowser
        }
        return .ok(workspaceID: ws.id, url: browserPanel.currentURL?.absoluteString ?? "")
    }

    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return .notFoundOrNotBrowser
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

    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> Bool {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let browserPanel = ws.browserPanel(for: surfaceID) else {
            return false
        }
        let webView = browserPanel.webView
        guard let window = webView.window,
              let fr = window.firstResponder as? NSView else {
            return false
        }
        return fr.isDescendant(of: webView)
    }

    // MARK: - import dialog

    func controlBrowserImportResolveDestinationProfile(
        query: String,
        createIfMissing: Bool
    ) -> ControlBrowserImportProfileResolution {
        let profiles = BrowserProfileStore.shared.profiles
        if let uuid = UUID(uuidString: query),
           profiles.contains(where: { $0.id == uuid }) {
            return .resolved(uuid)
        }
        if let profile = profiles.first(where: {
            $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
        }) {
            return .resolved(profile.id)
        }
        if createIfMissing {
            guard let createdProfileID = BrowserProfileStore.shared.createProfile(named: query)?.id else {
                return .createFailed
            }
            return .resolved(createdProfileID)
        }
        return .noMatch
    }

    func controlBrowserImportPresentDialog(
        scope: ControlBrowserImportScope?,
        destinationProfileID: UUID?
    ) {
        let mappedScope: BrowserImportScope? = scope.map {
            switch $0 {
            case .cookiesOnly: return .cookiesOnly
            case .historyOnly: return .historyOnly
            case .cookiesAndHistory: return .cookiesAndHistory
            case .everything: return .everything
            }
        }
        Task { @MainActor in
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: destinationProfileID,
                defaultScope: mappedScope
            )
        }
    }
}
