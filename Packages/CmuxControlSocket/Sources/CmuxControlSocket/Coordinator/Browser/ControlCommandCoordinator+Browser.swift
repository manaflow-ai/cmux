internal import Foundation

/// The browser navigation/panel/tabs/network/state domain (`browser.*` minus
/// the DOM-element automation commands), lifted byte-faithfully from the
/// former `TerminalController.v2Browser*` bodies. Each payload is built
/// directly as a ``JSONValue``; the encoded wire bytes match. The coordinator
/// owns param parsing, error shaping, and ref minting; the irreducibly
/// app-coupled work (workspace/panel resolution, WKWebView JavaScript, cookie
/// stores) runs behind the ``ControlBrowserContext`` seam.
///
/// This file carries the dispatch, the shared helpers, and the
/// open-split/navigation methods; the rest live in `+Browser2/3/4.swift`
/// (file-length budget).
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the browser domain, returning
    /// the typed result; returns `nil` otherwise so the caller can fall
    /// through. The integrator calls this from the core `handle`. The
    /// worker-lane browser methods (`browser.download.wait`,
    /// `browser.profiles.*`, `browser.import.cookies`) never reach the
    /// main-actor dispatch, so they are not listed here.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a browser method owned here.
    func handleBrowser(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.open_split":
            return browserOpenSplit(request.params)
        case "browser.navigate":
            return browserNavigate(request.params)
        case "browser.back":
            return browserNavSimple(request.params, action: .back)
        case "browser.forward":
            return browserNavSimple(request.params, action: .forward)
        case "browser.reload":
            return browserNavSimple(request.params, action: .reload)
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
        case "browser.snapshot":
            return browserSnapshot(request.params)
        case "browser.import.dialog":
            return browserImportDialog(request.params)
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
        case "browser.tab.new":
            return browserTabNew(request.params)
        case "browser.tab.list":
            return browserTabList(request.params)
        case "browser.tab.switch":
            return browserTabSwitch(request.params)
        case "browser.tab.close":
            return browserTabClose(request.params)
        case "browser.console.list":
            return browserConsoleList(request.params)
        case "browser.console.clear":
            return browserConsoleClear(request.params)
        case "browser.errors.list":
            return browserErrorsList(request.params)
        case "browser.state.save":
            return browserStateSave(request.params)
        case "browser.state.load":
            return browserStateLoad(request.params)
        case "browser.viewport.set":
            return browserNotSupported(
                "browser.viewport.set",
                details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP"
            )
        case "browser.geolocation.set":
            return browserNotSupported(
                "browser.geolocation.set",
                details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP"
            )
        case "browser.offline.set":
            return browserNotSupported(
                "browser.offline.set",
                details: "WKWebView does not expose reliable per-tab offline emulation"
            )
        case "browser.trace.start":
            return browserNotSupported(
                "browser.trace.start",
                details: "Playwright trace artifacts are not available on WKWebView"
            )
        case "browser.trace.stop":
            return browserNotSupported(
                "browser.trace.stop",
                details: "Playwright trace artifacts are not available on WKWebView"
            )
        case "browser.network.route":
            return browserNetworkRoute(request.params)
        case "browser.network.unroute":
            return browserNetworkUnroute(request.params)
        case "browser.network.requests":
            return browserNetworkRequests(request.params)
        case "browser.screencast.start":
            return browserNotSupported(
                "browser.screencast.start",
                details: "WKWebView does not expose CDP screencast streaming"
            )
        case "browser.screencast.stop":
            return browserNotSupported(
                "browser.screencast.stop",
                details: "WKWebView does not expose CDP screencast streaming"
            )
        case "browser.input_mouse":
            return browserNotSupported(
                "browser.input_mouse",
                details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll"
            )
        case "browser.input_keyboard":
            return browserNotSupported(
                "browser.input_keyboard",
                details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup"
            )
        case "browser.input_touch":
            return browserNotSupported(
                "browser.input_touch",
                details: "Raw CDP touch injection is unavailable on WKWebView"
            )
        default:
            return nil
        }
    }

    // MARK: - Shared helpers

    /// Maps the shared browser-surface resolution failure ladder onto the
    /// legacy `v2BrowserWithPanel` error results.
    func browserPanelFailureResult(_ failure: ControlBrowserPanelFailure) -> ControlCallResult {
        switch failure {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound(let paneID):
            return .err(
                code: "not_found",
                message: "Pane not found",
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .paneHasNoSelectedSurface(let paneID):
            return .err(
                code: "not_found",
                message: "Pane has no selected surface",
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .noFocusedBrowserSurface:
            return .err(code: "not_found", message: "No focused browser surface", data: nil)
        case .surfaceNotBrowser(let surfaceID):
            return .err(
                code: "invalid_params",
                message: "Surface is not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        }
    }

    /// The legacy `v2BrowserNotSupported` error shape.
    func browserNotSupported(_ method: String, details: String) -> ControlCallResult {
        .err(
            code: "not_supported",
            message: "\(method) is not supported on WKWebView",
            data: .object(["details": .string(details)])
        )
    }

    /// The legacy `v2RejectUnresolvedHandles`: an error if any of the given
    /// handle params is SUPPLIED but does not resolve (presence via the
    /// non-null check so an empty explicit handle is not treated as absent).
    func browserRejectUnresolvedHandles(
        _ params: [String: JSONValue],
        _ keys: [String]
    ) -> ControlCallResult? {
        for key in keys where hasNonNull(params, key) && uuid(params, key) == nil {
            return .err(code: "invalid_params", message: "Unresolved \(key)", data: nil)
        }
        return nil
    }

    /// Builds the shared browser-surface target from the request params
    /// (`surface_id`/`tab_id` explicit surface, `pane_id`, plus routing).
    func browserSurfaceTarget(_ params: [String: JSONValue]) -> ControlBrowserSurfaceTarget {
        ControlBrowserSurfaceTarget(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id") ?? uuid(params, "tab_id"),
            paneID: uuid(params, "pane_id")
        )
    }

    /// The legacy `v2JSONLiteral`: one JSON value as a JavaScript literal.
    func browserJSONLiteral(_ value: JSONValue) -> String {
        let object = value.foundationObject
        if let data = try? JSONSerialization.data(withJSONObject: [object], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if case .string(let s) = value {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    /// The standard workspace/surface/window identity payload of a browser
    /// action (the legacy `v2BrowserActionPayload`).
    func browserActionPayload(
        workspaceID: UUID,
        surfaceID: UUID,
        windowID: UUID?,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": ref(.surface, surfaceID),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
        ]
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    /// The workspace/surface identity prefix shared by the resolved-panel
    /// payloads (`cookies.*`, `storage.*`, `console.*`, `state.*`, …).
    func browserIdentityFields(_ identity: ControlBrowserPanelIdentity) -> [String: JSONValue] {
        [
            "workspace_id": .string(identity.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, identity.workspaceID),
            "surface_id": .string(identity.surfaceID.uuidString),
            "surface_ref": ref(.surface, identity.surfaceID),
        ]
    }

    // MARK: - open_split

    /// `browser.open_split` — open a browser in a split (or externally per the
    /// link-open rules / browser-disabled fallback).
    func browserOpenSplit(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = string(params, "url")
        let respectExternalOpenRules = bool(params, "respect_external_open_rules") ?? false

        if context?.controlBrowserIsAvailabilityDisabled() == true {
            if context?.controlBrowserIsDiffViewerURL(urlStr) == true {
                return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
            }
            let outcome = context?.controlBrowserDisabledExternalOpen(rawURL: urlStr, routing: routing) ?? .noURL
            return browserDisabledResult(outcome)
        }
        switch context?.controlBrowserRegisterDiffViewer(
            urlString: urlStr,
            token: string(params, "diff_viewer_token"),
            files: params["diff_viewer_files"]
        ) ?? .notApplicable {
        case .notApplicable, .registered:
            break
        case .missingOrInvalidAllowlist:
            return .err(code: "invalid_params", message: "Missing or invalid trusted diff viewer allowlist", data: nil)
        case .invalidAllowlist:
            return .err(code: "invalid_params", message: "Invalid trusted diff viewer allowlist", data: nil)
        case .invalidAllowlistDetails(let details):
            return .err(
                code: "invalid_params",
                message: "Invalid trusted diff viewer allowlist",
                data: .object(["details": .string(details)])
            )
        }

        let inputs = ControlBrowserOpenSplitInputs(
            urlString: urlStr,
            respectExternalOpenRules: respectExternalOpenRules,
            sourceSurfaceID: uuid(params, "surface_id"),
            focusRequested: bool(params, "focus") ?? false,
            showOmnibar: bool(params, "show_omnibar") ?? true,
            transparentBackground: bool(params, "transparent_background") ?? false,
            bypassRemoteProxy: bool(params, "bypass_remote_proxy")
        )
        switch context?.controlBrowserOpenSplit(routing: routing, inputs: inputs) ?? .workspaceNotFound {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .externalOpenFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .openedExternally(let windowID, let workspaceID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .null,
                "pane_ref": .null,
                "surface_id": .null,
                "surface_ref": .null,
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
        case .created(let snapshot):
            return .ok(.object([
                "window_id": orNull(snapshot.windowID?.uuidString),
                "window_ref": ref(.window, snapshot.windowID),
                "workspace_id": .string(snapshot.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, snapshot.workspaceID),
                "pane_id": orNull(snapshot.paneID?.uuidString),
                "pane_ref": ref(.pane, snapshot.paneID),
                "surface_id": .string(snapshot.surfaceID.uuidString),
                "surface_ref": ref(.surface, snapshot.surfaceID),
                "source_surface_id": .string(snapshot.sourceSurfaceID.uuidString),
                "source_surface_ref": ref(.surface, snapshot.sourceSurfaceID),
                "source_pane_id": orNull(snapshot.sourcePaneID?.uuidString),
                "source_pane_ref": ref(.pane, snapshot.sourcePaneID),
                "target_pane_id": orNull(snapshot.paneID?.uuidString),
                "target_pane_ref": ref(.pane, snapshot.paneID),
                "created_split": .bool(snapshot.createdSplit),
                "placement_strategy": .string(snapshot.placementStrategy),
                "show_omnibar": .bool(snapshot.showOmnibar),
                "transparent_background": .bool(snapshot.transparentBackground),
                "bypass_remote_proxy": .bool(snapshot.bypassRemoteProxy),
            ]))
        }
    }

    // MARK: - navigate / history nav

    /// `browser.navigate` — smart-navigate a browser surface.
    func browserNavigate(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let url = string(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }
        switch context?.controlBrowserNavigate(routing: routing, surfaceID: surfaceID, urlString: url)
            ?? .notFoundOrNotBrowser {
        case .notFoundOrNotBrowser:
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .ok(let workspaceID, let windowID):
            var payload: [String: JSONValue] = [
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]
            browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
            return .ok(.object(payload))
        }
    }

    /// `browser.back`/`forward`/`reload` — the legacy `v2BrowserNavSimple`.
    func browserNavSimple(
        _ params: [String: JSONValue],
        action: ControlBrowserNavAction
    ) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        switch context?.controlBrowserNavAction(routing: routing, surfaceID: surfaceID, action: action)
            ?? .notFoundOrNotBrowser {
        case .notFoundOrNotBrowser:
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .ok(let workspaceID, let windowID):
            var payload: [String: JSONValue] = [
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]
            browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
            return .ok(.object(payload))
        }
    }

    /// The legacy `v2BrowserAppendPostSnapshot`: optionally appends a
    /// post-action snapshot (built through the coordinator's own
    /// `browserSnapshot`) to an action payload.
    func browserAppendPostSnapshot(
        _ params: [String: JSONValue],
        surfaceID: UUID,
        payload: inout [String: JSONValue]
    ) {
        guard bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: JSONValue] = [
            "surface_id": .string(surfaceID.uuidString),
            "interactive": .bool(bool(params, "snapshot_interactive") ?? true),
            "cursor": .bool(bool(params, "snapshot_cursor") ?? false),
            "compact": .bool(bool(params, "snapshot_compact") ?? true),
            "max_depth": .int(Int64(max(0, int(params, "snapshot_max_depth") ?? 10))),
        ]
        if let selector = string(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = .string(selector)
        }

        switch browserSnapshot(snapshotParams) {
        case .ok(let snapshotValue):
            guard case .object(let snapshot) = snapshotValue else {
                payload["post_action_snapshot_error"] = .object([
                    "code": .string("internal_error"),
                    "message": .string("Invalid snapshot payload"),
                ])
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(let code, let message, let data):
            payload["post_action_snapshot_error"] = .object([
                "code": .string(code),
                "message": .string(message),
                "data": data ?? .null,
            ])
        }
    }
}
