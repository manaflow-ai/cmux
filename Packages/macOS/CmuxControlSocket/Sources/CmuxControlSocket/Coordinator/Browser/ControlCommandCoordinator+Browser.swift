internal import Foundation

/// The non-JS-evaluating, main-actor `browser.*` domain (`browser.open_split` /
/// `browser.react_grab.toggle` / `browser.devtools.toggle` /
/// `browser.console.show` / `browser.focus_mode.set` / `browser.zoom.set` /
/// `browser.history.clear` / `browser.url.get` / `browser.focus_webview` /
/// `browser.is_webview_focused`), lifted byte-faithfully from the former
/// `TerminalController.v2Browser*` bodies.
///
/// The coordinator owns the param parsing/validation and builds each payload
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries; the resulting Foundation object is identical, so the encoded
/// wire bytes match). The app-coupled work (URL/diff-viewer resolution, split
/// creation, Web Inspector, focus mode, zoom, first-responder moves) runs
/// behind the ``ControlBrowserContext`` seam.
///
/// The JS-evaluating `browser.*` methods are NOT here: PR 5778 moved them onto
/// the socket-worker lane, which the `@MainActor` coordinator cannot host, so
/// they stay on the app-side dispatcher.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the non-JS-eval browser domain
    /// this coordinator owns, returning the typed result; returns `nil`
    /// otherwise so the caller can fall through (the JS-eval browser methods are
    /// served by the legacy app-side dispatcher).
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    func handleBrowser(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.open_split":
            return browserOpenSplit(request.params)
        case "browser.react_grab.toggle":
            return browserReactGrabToggle(request.params)
        case "browser.devtools.toggle":
            return browserDevToolsToggle(request.params)
        case "browser.console.show":
            return browserConsoleShow(request.params)
        case "browser.focus_mode.set":
            return browserFocusModeSet(request.params)
        case "browser.zoom.set":
            return browserZoomSet(request.params)
        case "browser.history.clear":
            return browserHistoryClear(request.params)
        case "browser.url.get":
            return browserGetURL(request.params)
        case "browser.focus_webview":
            return browserFocusWebView(request.params)
        case "browser.is_webview_focused":
            return browserIsWebViewFocused(request.params)
        case "browser.cookies.get":
            return browserCookiesGet(request.params)
        case "browser.cookies.set":
            return browserCookiesSet(request.params)
        case "browser.cookies.clear":
            return browserCookiesClear(request.params)
        case "browser.storage.get":
            return browserStorageGet(request.params)
        case "browser.storage.set":
            return browserStorageSet(request.params)
        case "browser.storage.clear":
            return browserStorageClear(request.params)
        case "browser.addinitscript":
            return browserAddInitScript(request.params)
        case "browser.addscript":
            return browserAddScript(request.params)
        case "browser.addstyle":
            return browserAddStyle(request.params)
        case "browser.dialog.accept":
            return browserDialogRespond(request.params, accept: true)
        case "browser.dialog.dismiss":
            return browserDialogRespond(request.params, accept: false)
        case "browser.import.dialog":
            return browserImportDialog(request.params)
        default:
            return nil
        }
    }

    /// The browser-domain view of the seam (the v2 counterpart of
    /// `browserPanelContext`).
    private var browserContext: (any ControlBrowserContext)? {
        context
    }

    /// Rejects any of `keys` that is SUPPLIED (present and non-null) but does
    /// not resolve to a UUID/ref (the typed twin of `v2RejectUnresolvedHandles`).
    private func rejectUnresolvedHandles(
        _ params: [String: JSONValue],
        _ keys: [String]
    ) -> ControlCallResult? {
        for key in keys where hasNonNull(params, key) && uuid(params, key) == nil {
            return .err(code: "invalid_params", message: "Unresolved \(key)", data: nil)
        }
        return nil
    }

    /// The standard window/workspace/surface identity payload for a focused
    /// browser action (the typed twin of `v2BrowserActionPayload`).
    private func browserActionPayload(
        _ acted: ControlBrowserActedSurface,
        extra: [String: JSONValue]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "workspace_id": .string(acted.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, acted.workspaceID),
            "surface_id": .string(acted.surfaceID.uuidString),
            "surface_ref": ref(.surface, acted.surfaceID),
            "window_id": orNull(acted.windowID?.uuidString),
            "window_ref": ref(.window, acted.windowID),
        ]
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    // MARK: - open_split

    /// `browser.open_split` — create a browser split off the focused panel.
    private func browserOpenSplit(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        let diffViewerFiles: [JSONValue]?
        if case .array(let raw)? = params["diff_viewer_files"] {
            diffViewerFiles = raw
        } else {
            diffViewerFiles = nil
        }

        let resolution = browserContext?.controlBrowserOpenSplit(
            routing: routing,
            rawURLString: string(params, "url"),
            respectExternalOpenRules: bool(params, "respect_external_open_rules") ?? false,
            diffViewerToken: string(params, "diff_viewer_token"),
            diffViewerFiles: diffViewerFiles,
            explicitSourceSurfaceID: uuid(params, "surface_id"),
            requestedFocus: bool(params, "focus") ?? false,
            showOmnibar: bool(params, "show_omnibar") ?? true,
            transparentBackground: bool(params, "transparent_background") ?? false,
            bypassRemoteProxyParam: bool(params, "bypass_remote_proxy")
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .unresolvableURL(let rawURL):
            return .err(
                code: "invalid_params",
                message: "Could not resolve URL or search query",
                data: .object(["url": .string(rawURL)])
            )
        case .browserDisabled:
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        case .disabledExternalInvalidURL(let rawURL):
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: .object(["url": .string(rawURL)])
            )
        case .disabledExternalNoURL:
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        case .disabledExternalOpenFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .disabledExternalOpened(let windowID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": orNull(nil),
                "workspace_ref": ref(.workspace, nil),
                "pane_id": orNull(nil),
                "pane_ref": ref(.pane, nil),
                "surface_id": orNull(nil),
                "surface_ref": ref(.surface, nil),
                "created_split": .bool(false),
                "opened_externally": .bool(true),
                "browser_disabled": .bool(true),
                "placement_strategy": .string("external_browser_disabled"),
                "url": .string(url),
            ]))
        case .invalidDiffViewerAllowlist(let message, let details):
            if let details {
                return .err(
                    code: "invalid_params",
                    message: message,
                    data: .object(["details": .string(details)])
                )
            }
            return .err(code: "invalid_params", message: message, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .externalOpenRespectedFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .externalOpenRespected(let windowID, let workspaceID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(nil),
                "pane_ref": ref(.pane, nil),
                "surface_id": orNull(nil),
                "surface_ref": ref(.surface, nil),
                "created_split": .bool(false),
                "placement_strategy": .string("external"),
                "opened_externally": .bool(true),
                "url": .string(url),
            ]))
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface to split", data: nil)
        case .sourceSurfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Source surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create browser", data: nil)
        case .created(let success):
            return .ok(.object([
                "window_id": orNull(success.windowID?.uuidString),
                "window_ref": ref(.window, success.windowID),
                "workspace_id": .string(success.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, success.workspaceID),
                "pane_id": orNull(success.targetPaneID?.uuidString),
                "pane_ref": ref(.pane, success.targetPaneID),
                "surface_id": .string(success.browserSurfaceID.uuidString),
                "surface_ref": ref(.surface, success.browserSurfaceID),
                "source_surface_id": .string(success.sourceSurfaceID.uuidString),
                "source_surface_ref": ref(.surface, success.sourceSurfaceID),
                "source_pane_id": orNull(success.sourcePaneID?.uuidString),
                "source_pane_ref": ref(.pane, success.sourcePaneID),
                "target_pane_id": orNull(success.targetPaneID?.uuidString),
                "target_pane_ref": ref(.pane, success.targetPaneID),
                "created_split": .bool(success.createdSplit),
                "placement_strategy": .string(success.placementStrategy),
                "show_omnibar": .bool(success.omnibarVisible),
                "transparent_background": .bool(success.transparentBackground),
                "bypass_remote_proxy": .bool(success.bypassRemoteProxy),
            ]))
        }
    }

    // MARK: - react_grab.toggle

    /// `browser.react_grab.toggle` — toggle React Grab on the resolved browser.
    private func browserReactGrabToggle(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = rejectUnresolvedHandles(params, ["surface_id", "return_to", "workspace_id", "window_id"]) {
            return error
        }
        let resolution = browserContext?.controlBrowserReactGrabToggle(
            routing: routing,
            browserSurfaceID: uuid(params, "surface_id"),
            returnSurfaceID: uuid(params, "return_to")
        ) ?? .noBrowserSurface
        switch resolution {
        case .noBrowserSurface:
            return .err(code: "not_found", message: "No browser surface to toggle React Grab on", data: nil)
        case .acted(let acted):
            return .ok(browserActionPayload(acted, extra: ["toggled": .bool(true)]))
        }
    }

    // MARK: - devtools.toggle

    /// `browser.devtools.toggle` — toggle the Web Inspector.
    private func browserDevToolsToggle(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = rejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) {
            return error
        }
        let resolution = browserContext?.controlBrowserDevToolsToggle(
            routing: routing,
            explicitSurfaceID: uuid(params, "surface_id"),
            surfaceWasSupplied: hasNonNull(params, "surface_id")
        ) ?? .noBrowserSurface
        switch resolution {
        case .noBrowserSurface:
            return .err(code: "not_found", message: "No browser surface found", data: nil)
        case .acted(let acted):
            return .ok(browserActionPayload(acted, extra: ["handled": .bool(acted.flag)]))
        }
    }

    // MARK: - console.show

    /// `browser.console.show` — open the Web Inspector console.
    private func browserConsoleShow(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = rejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) {
            return error
        }
        let resolution = browserContext?.controlBrowserConsoleShow(
            routing: routing,
            explicitSurfaceID: uuid(params, "surface_id"),
            surfaceWasSupplied: hasNonNull(params, "surface_id")
        ) ?? .noBrowserSurface
        switch resolution {
        case .noBrowserSurface:
            return .err(code: "not_found", message: "No browser surface found", data: nil)
        case .acted(let acted):
            return .ok(browserActionPayload(acted, extra: ["handled": .bool(acted.flag)]))
        }
    }

    // MARK: - focus_mode.set

    /// `browser.focus_mode.set` — enter/exit/toggle browser focus mode.
    private func browserFocusModeSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = rejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) {
            return error
        }
        let mode = (string(params, "mode") ?? "toggle").lowercased()
        let enterAliases: Set<String> = ["enter", "on", "true", "active"]
        let exitAliases: Set<String> = ["exit", "off", "false", "inactive"]
        let intent: ControlBrowserFocusModeIntent
        if mode == "toggle" {
            intent = .toggle
        } else if enterAliases.contains(mode) {
            intent = .enter
        } else if exitAliases.contains(mode) {
            intent = .exit
        } else {
            return .err(
                code: "invalid_params",
                message: "mode must be one of: enter, exit, toggle, on, off",
                data: nil
            )
        }
        let resolution = browserContext?.controlBrowserFocusModeSet(
            routing: routing,
            explicitSurfaceID: uuid(params, "surface_id"),
            surfaceWasSupplied: hasNonNull(params, "surface_id"),
            intent: intent
        ) ?? .noBrowserSurface
        switch resolution {
        case .noBrowserSurface:
            return .err(code: "not_found", message: "No browser surface found", data: nil)
        case .acted(let acted):
            return .ok(browserActionPayload(
                acted,
                extra: ["handled": .bool(acted.flag), "mode": .string(mode)]
            ))
        }
    }

    // MARK: - zoom.set

    /// `browser.zoom.set` — zoom in/out/reset.
    private func browserZoomSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = rejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) {
            return error
        }
        let directionRaw = (string(params, "direction") ?? "").lowercased()
        guard let direction = ControlBrowserZoomDirection(rawValue: directionRaw) else {
            return .err(
                code: "invalid_params",
                message: "direction must be one of: in, out, reset",
                data: nil
            )
        }
        let resolution = browserContext?.controlBrowserZoomSet(
            routing: routing,
            explicitSurfaceID: uuid(params, "surface_id"),
            surfaceWasSupplied: hasNonNull(params, "surface_id"),
            direction: direction
        ) ?? .noBrowserSurface
        switch resolution {
        case .noBrowserSurface:
            return .err(code: "not_found", message: "No browser surface found", data: nil)
        case .acted(let acted):
            return .ok(browserActionPayload(
                acted,
                extra: ["handled": .bool(acted.flag), "direction": .string(directionRaw)]
            ))
        }
    }

    // MARK: - history.clear

    /// `browser.history.clear` — clear the default profile's browser history
    /// (destructive: requires `force=true`).
    private func browserHistoryClear(_ params: [String: JSONValue]) -> ControlCallResult {
        guard bool(params, "force") == true else {
            return .err(
                code: "invalid_params",
                message: "browser.history.clear requires force=true",
                data: nil
            )
        }
        browserContext?.controlBrowserClearDefaultHistory()
        return .ok(.object(["cleared": .bool(true), "scope": .string("default_profile")]))
    }

    // MARK: - url.get

    /// `browser.url.get` — the resolved browser surface's current URL.
    private func browserGetURL(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = browserContext?.controlBrowserCurrentURL(routing: routing, surfaceID: surfaceID)
            ?? .notFound
        switch resolution {
        case .notFound:
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .resolved(let workspaceID, let url):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "url": .string(url),
            ]))
        }
    }

    // MARK: - focus_webview

    /// `browser.focus_webview` — move first responder into the web view.
    private func browserFocusWebView(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = browserContext?.controlBrowserFocusWebView(routing: routing, surfaceID: surfaceID)
            ?? .notFound
        switch resolution {
        case .notFound:
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .webViewNotInWindow:
            return .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
        case .webViewHidden:
            return .err(code: "invalid_state", message: "WebView is hidden", data: nil)
        case .focusDidNotMove:
            return .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
        case .focused:
            return .ok(.object(["focused": .bool(true)]))
        }
    }

    // MARK: - is_webview_focused

    /// `browser.is_webview_focused` — whether the web view holds focus.
    private func browserIsWebViewFocused(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard browserContext?.controlBrowserRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = browserContext?.controlBrowserIsWebViewFocused(routing: routing, surfaceID: surfaceID)
            ?? ControlBrowserIsWebViewFocusedResolution(focused: false)
        return .ok(.object(["focused": .bool(resolution.focused)]))
    }
}
