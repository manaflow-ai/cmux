internal import Foundation

/// Browser domain, part 2: the focused-browser actions, history/url/web-view
/// focus reads, and the import dialog. See `+Browser.swift` for the dispatch.
extension ControlCommandCoordinator {
    // MARK: - react grab

    /// `browser.react_grab.toggle` — toggle React Grab on the target browser.
    func browserReactGrabToggle(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = browserRejectUnresolvedHandles(params, ["surface_id", "return_to", "workspace_id", "window_id"]) {
            return error
        }
        switch context?.controlBrowserReactGrabToggle(
            routing: routing,
            browserSurfaceID: uuid(params, "surface_id"),
            returnSurfaceID: uuid(params, "return_to")
        ) ?? .notFound {
        case .notFound:
            return .err(code: "not_found", message: "No browser surface to toggle React Grab on", data: nil)
        case .toggled(let workspaceID, let surfaceID, let windowID):
            return .ok(browserActionPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                windowID: windowID,
                extra: ["toggled": .bool(true)]
            ))
        }
    }

    // MARK: - focused-browser actions

    /// `browser.devtools.toggle` — toggle the developer tools.
    func browserDevToolsToggle(_ params: [String: JSONValue]) -> ControlCallResult {
        browserFocusedAction(params) { context, routing, target in
            context.controlBrowserDevToolsToggle(routing: routing, target: target)
        }
    }

    /// `browser.console.show` — show the developer-tools console.
    func browserConsoleShow(_ params: [String: JSONValue]) -> ControlCallResult {
        browserFocusedAction(params) { context, routing, target in
            context.controlBrowserConsoleShow(routing: routing, target: target)
        }
    }

    /// `browser.focus_mode.set` — enter/exit/toggle browser focus mode.
    func browserFocusModeSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let mode = (string(params, "mode") ?? "toggle").lowercased()
        let enterAliases: Set<String> = ["enter", "on", "true", "active"]
        let exitAliases: Set<String> = ["exit", "off", "false", "inactive"]
        guard mode == "toggle" || enterAliases.contains(mode) || exitAliases.contains(mode) else {
            return .err(
                code: "invalid_params",
                message: "mode must be one of: enter, exit, toggle, on, off",
                data: nil
            )
        }
        let action: ControlBrowserFocusModeAction
        if enterAliases.contains(mode) {
            action = .activate
        } else if exitAliases.contains(mode) {
            action = .deactivate
        } else {
            action = .toggle
        }
        return browserFocusedAction(params, extra: ["mode": .string(mode)]) { context, routing, target in
            context.controlBrowserFocusModeSet(routing: routing, target: target, action: action)
        }
    }

    /// `browser.zoom.set` — zoom in/out/reset.
    func browserZoomSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let direction = (string(params, "direction") ?? "").lowercased()
        guard ["in", "out", "reset"].contains(direction) else {
            return .err(
                code: "invalid_params",
                message: "direction must be one of: in, out, reset",
                data: nil
            )
        }
        let mapped: ControlBrowserZoomDirection
        switch direction {
        case "in": mapped = .zoomIn
        case "out": mapped = .zoomOut
        default: mapped = .reset
        }
        return browserFocusedAction(params, extra: ["direction": .string(direction)]) { context, routing, target in
            context.controlBrowserZoomSet(routing: routing, target: target, direction: mapped)
        }
    }

    /// The shared guard/dispatch/payload shape of the focused-browser actions
    /// (`devtools.toggle`, `console.show`, `focus_mode.set`, `zoom.set`):
    /// TabManager guard, unresolved-handle rejection, the seam call, and the
    /// `v2BrowserActionPayload` + `handled` payload.
    private func browserFocusedAction(
        _ params: [String: JSONValue],
        extra: [String: JSONValue] = [:],
        _ perform: (
            any ControlCommandContext,
            ControlRoutingSelectors,
            ControlBrowserFocusedActionTarget
        ) -> ControlBrowserHandledResolution
    ) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let context, context.controlSurfaceRoutingResolvesTabManager(routing: routing) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = browserRejectUnresolvedHandles(params, ["surface_id", "workspace_id", "window_id"]) {
            return error
        }
        let target = ControlBrowserFocusedActionTarget(
            hasSurfaceParam: hasNonNull(params, "surface_id"),
            surfaceID: uuid(params, "surface_id")
        )
        switch perform(context, routing, target) {
        case .notFound:
            return .err(code: "not_found", message: "No browser surface found", data: nil)
        case .acted(let workspaceID, let surfaceID, let windowID, let handled):
            var fields = extra
            fields["handled"] = .bool(handled)
            return .ok(browserActionPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                windowID: windowID,
                extra: fields
            ))
        }
    }

    // MARK: - history / url / web-view focus

    /// `browser.history.clear` — clear the default profile's history (gated on
    /// explicit `force=true`, as legacy).
    func browserHistoryClear(_ params: [String: JSONValue]) -> ControlCallResult {
        guard bool(params, "force") == true else {
            return .err(
                code: "invalid_params",
                message: "browser.history.clear requires force=true",
                data: nil
            )
        }
        context?.controlBrowserClearDefaultProfileHistory()
        return .ok(.object([
            "cleared": .bool(true),
            "scope": .string("default_profile"),
        ]))
    }

    /// `browser.url.get` — the surface's current URL (ids only, no refs, as
    /// legacy).
    func browserGetURL(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        switch context?.controlBrowserCurrentURL(routing: routing, surfaceID: surfaceID)
            ?? .notFoundOrNotBrowser {
        case .notFoundOrNotBrowser:
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .ok(let workspaceID, let url):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "url": .string(url),
            ]))
        }
    }

    /// `browser.focus_webview` — move first responder into the web view.
    func browserFocusWebView(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        switch context?.controlBrowserFocusWebView(routing: routing, surfaceID: surfaceID)
            ?? .notFoundOrNotBrowser {
        case .notFoundOrNotBrowser:
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

    /// `browser.is_webview_focused` — whether first responder is inside the
    /// web view (`false` when the surface does not resolve, as legacy).
    func browserIsWebViewFocused(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let focused = context?.controlBrowserIsWebViewFocused(routing: routing, surfaceID: surfaceID) ?? false
        return .ok(.object(["focused": .bool(focused)]))
    }

    // MARK: - import dialog

    /// `browser.import.dialog` — present the browser data import dialog.
    func browserImportDialog(_ params: [String: JSONValue]) -> ControlCallResult {
        let scope: ControlBrowserImportScope?
        if params["scope"] != nil {
            guard let raw = string(params, "scope")?.lowercased(), !raw.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "scope must be a non-empty string",
                    data: .object(["param": .string("scope")])
                )
            }
            switch raw {
            case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
                scope = .cookiesOnly
            case "history", "historyonly", "history_only", "history-only":
                scope = .historyOnly
            case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
                scope = .cookiesAndHistory
            case "everything", "all":
                scope = .everything
            default:
                return .err(
                    code: "invalid_params",
                    message: "scope is invalid",
                    data: .object(["param": .string("scope")])
                )
            }
        } else {
            scope = nil
        }

        let destinationProfileID: UUID?
        if params["destination_profile"] != nil {
            guard let query = string(params, "destination_profile"), !query.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile must be a non-empty string",
                    data: .object(["param": .string("destination_profile")])
                )
            }
            let createIfMissing = bool(params, "create_destination_profile") == true
                || bool(params, "create_profile") == true
            switch context?.controlBrowserImportResolveDestinationProfile(
                query: query,
                createIfMissing: createIfMissing
            ) ?? .noMatch {
            case .resolved(let profileID):
                destinationProfileID = profileID
            case .createFailed:
                return .err(
                    code: "invalid_params",
                    message: "destination_profile could not be created",
                    data: .object(["param": .string("destination_profile")])
                )
            case .noMatch:
                return .err(
                    code: "invalid_params",
                    message: "destination_profile does not match a cmux browser profile",
                    data: .object(["param": .string("destination_profile")])
                )
            }
        } else {
            destinationProfileID = nil
        }

        context?.controlBrowserImportPresentDialog(scope: scope, destinationProfileID: destinationProfileID)
        return .ok(.object([
            "opened": .bool(true),
            "scope": scope.map { JSONValue.string($0.rawValue) } ?? .null,
        ]))
    }
}
