internal import Foundation

/// Browser domain, part 4: tabs, console/error logs, state save/load, and the
/// unsupported-network commands. See `+Browser.swift` for the dispatch.
extension ControlCommandCoordinator {
    // MARK: - tabs

    /// `browser.tab.list` — the workspace's browser tabs.
    func browserTabList(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let snapshot = context?.controlBrowserTabList(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        let tabs: [JSONValue] = snapshot.tabs.enumerated().map { index, tab in
            .object([
                "id": .string(tab.surfaceID.uuidString),
                "ref": ref(.surface, tab.surfaceID),
                "index": .int(Int64(index)),
                "title": .string(tab.title),
                "url": .string(tab.url),
                "focused": .bool(tab.isFocused),
                "pane_id": orNull(tab.paneID?.uuidString),
                "pane_ref": ref(.pane, tab.paneID),
            ])
        }
        return .ok(.object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "surface_id": orNull(snapshot.focusedSurfaceID?.uuidString),
            "surface_ref": ref(.surface, snapshot.focusedSurfaceID),
            "tabs": .array(tabs),
        ]))
    }

    /// `browser.tab.new` — create a browser tab in the resolved pane.
    func browserTabNew(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = string(params, "url")
        guard context?.controlBrowserIsAvailabilityEnabled() == true else {
            let outcome = context?.controlBrowserDisabledExternalOpen(rawURL: urlStr, routing: routing) ?? .noURL
            return browserDisabledResult(outcome)
        }
        switch context?.controlBrowserTabNew(
            routing: routing,
            urlString: urlStr,
            explicitPaneID: uuid(params, "pane_id") ?? uuid(params, "target_pane_id"),
            paneFromSurfaceID: uuid(params, "surface_id")
        ) ?? .workspaceNotFound {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound:
            return .err(code: "not_found", message: "Target pane not found", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        case .created(let workspaceID, let paneID, let surfaceID, let url):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "url": .string(url),
            ]))
        }
    }

    /// `browser.tab.switch` — focus a browser tab.
    func browserTabSwitch(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch context?.controlBrowserTabSwitch(
            routing: routing,
            explicitID: uuid(params, "target_surface_id") ?? uuid(params, "tab_id"),
            index: int(params, "index"),
            surfaceID: uuid(params, "surface_id")
        ) ?? .workspaceNotFound {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .tabNotFound:
            return .err(code: "not_found", message: "Browser tab not found", data: nil)
        case .switched(let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    /// `browser.tab.close` — close a browser tab.
    func browserTabClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch context?.controlBrowserTabClose(
            routing: routing,
            explicitID: uuid(params, "target_surface_id") ?? uuid(params, "tab_id"),
            index: int(params, "index"),
            surfaceID: uuid(params, "surface_id")
        ) ?? .workspaceNotFound {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noBrowserTabs:
            return .err(code: "not_found", message: "No browser tabs", data: nil)
        case .tabNotFound:
            return .err(code: "not_found", message: "Browser tab not found", data: nil)
        case .lastSurface:
            return .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
        case .closeFailed(let surfaceID):
            return .err(
                code: "internal_error",
                message: "Failed to close browser tab",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .closed(let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    // MARK: - console / error logs

    /// `browser.console.list` — drain (optionally clearing) the page console log.
    func browserConsoleList(_ params: [String: JSONValue]) -> ControlCallResult {
        browserTelemetryLogList(
            params,
            logExpression: "window.__cmuxConsoleLog",
            clearAssignment: "window.__cmuxConsoleLog = [];",
            itemsKey: "entries"
        )
    }

    /// `browser.console.clear` — `console.list` with `clear=true` (the legacy
    /// param-forwarding shape).
    func browserConsoleClear(_ params: [String: JSONValue]) -> ControlCallResult {
        var withClear = params
        withClear["clear"] = .bool(true)
        return browserConsoleList(withClear)
    }

    /// `browser.errors.list` — drain (optionally clearing) the page error log.
    func browserErrorsList(_ params: [String: JSONValue]) -> ControlCallResult {
        browserTelemetryLogList(
            params,
            logExpression: "window.__cmuxErrorLog",
            clearAssignment: "window.__cmuxErrorLog = [];",
            itemsKey: "errors"
        )
    }

    /// The shared console/error log reader (the two legacy bodies differed
    /// only in the log global and the payload key).
    private func browserTelemetryLogList(
        _ params: [String: JSONValue],
        logExpression: String,
        clearAssignment: String,
        itemsKey: String
    ) -> ControlCallResult {
        let clear = bool(params, "clear") ?? false
        let clearLiteral = clear ? "true" : "false"
        let script = """
        (() => {
          const items = Array.isArray(\(logExpression)) ? \(logExpression).slice() : [];
          if (\(clearLiteral)) {
            \(clearAssignment)
          }
          return { ok: true, items };
        })()
        """
        switch context?.controlBrowserRunScript(
            target: browserSurfaceTarget(params),
            script: script,
            timeout: 5.0,
            mode: .pageWorld(installTelemetryHooks: true)
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .resolved(let identity, let outcome):
            switch outcome {
            case .jsError(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .undefined:
                var payload = browserIdentityFields(identity)
                payload[itemsKey] = .array([])
                payload["count"] = .int(0)
                return .ok(.object(payload))
            case .value(let value):
                var items: [JSONValue] = []
                if case .object(let dict) = value, case .array(let raw)? = dict["items"] {
                    items = raw
                }
                var payload = browserIdentityFields(identity)
                payload[itemsKey] = .array(items)
                payload["count"] = .int(Int64(items.count))
                return .ok(.object(payload))
            }
        }
    }

    // MARK: - state save / load

    /// `browser.state.save` — capture URL/cookies/storage/frame selector and
    /// write the state file (the file write happens here; the capture is one
    /// resolved-panel pass app-side).
    func browserStateSave(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let path = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        let storageScript = """
        (() => {
          const readStorage = (st) => {
            const out = {};
            if (!st) return out;
            for (let i = 0; i < st.length; i++) {
              const k = st.key(i);
              out[k] = st.getItem(k);
            }
            return out;
          };
          return {
            local: readStorage(window.localStorage),
            session: readStorage(window.sessionStorage)
          };
        })()
        """
        switch context?.controlBrowserStateCapture(
            target: browserSurfaceTarget(params),
            storageScript: storageScript
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .captured(let capture):
            let cookieObjects = capture.cookies.map(browserCookieObject)
            let state: JSONValue = .object([
                "url": .string(capture.url),
                "cookies": .array(cookieObjects),
                "storage": capture.storage,
                "frame_selector": orNull(capture.frameSelector),
            ])
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: state.foundationObject,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(
                    code: "internal_error",
                    message: "Failed to write state file",
                    data: .object([
                        "path": .string(path),
                        "error": .string(error.localizedDescription),
                    ])
                )
            }
            var payload = browserIdentityFields(capture.identity)
            payload["path"] = .string(path)
            payload["cookies"] = .int(Int64(cookieObjects.count))
            return .ok(.object(payload))
        }
    }

    /// `browser.state.load` — read the state file (here) and apply it in one
    /// resolved-panel pass app-side.
    func browserStateLoad(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let path = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        let fileURL = URL(fileURLWithPath: path)
        let raw: [String: Any]
        do {
            let data = try Data(contentsOf: fileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .err(
                    code: "invalid_params",
                    message: "State file must contain a JSON object",
                    data: .object(["path": .string(path)])
                )
            }
            raw = object
        } catch {
            return .err(
                code: "not_found",
                message: "Failed to read state file",
                data: .object([
                    "path": .string(path),
                    "error": .string(error.localizedDescription),
                ])
            )
        }

        let frameSelector: String?
        if let selector = raw["frame_selector"] as? String, !selector.isEmpty {
            frameSelector = selector
        } else {
            frameSelector = nil
        }

        let navigateTo: String?
        if let urlStr = raw["url"] as? String, !urlStr.isEmpty {
            navigateTo = urlStr
        } else {
            navigateTo = nil
        }

        var cookieRows: [JSONValue] = []
        if let rows = raw["cookies"] as? [[String: Any]] {
            cookieRows = rows.compactMap { JSONValue(foundationObject: $0) }
        }

        let storageScript: String?
        if let storage = raw["storage"] as? [String: Any],
           let storageValue = JSONValue(foundationObject: storage) {
            let storageLiteral = browserJSONLiteral(storageValue)
            storageScript = """
            (() => {
              const payload = \(storageLiteral);
              const apply = (st, data) => {
                if (!st || !data || typeof data !== 'object') return;
                st.clear();
                for (const [k, v] of Object.entries(data)) {
                  st.setItem(String(k), v == null ? '' : String(v));
                }
              };
              apply(window.localStorage, payload.local);
              apply(window.sessionStorage, payload.session);
              return true;
            })()
            """
        } else {
            storageScript = nil
        }

        switch context?.controlBrowserStateApply(
            target: browserSurfaceTarget(params),
            frameSelector: frameSelector,
            navigateToURLString: navigateTo,
            cookieRows: cookieRows,
            storageScript: storageScript
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .applied(let identity):
            var payload = browserIdentityFields(identity)
            payload["path"] = .string(path)
            payload["loaded"] = .bool(true)
            return .ok(.object(payload))
        }
    }

    // MARK: - unsupported network commands

    /// `browser.network.route` — record the attempt, then `not_supported`.
    func browserNetworkRoute(_ params: [String: JSONValue]) -> ControlCallResult {
        if let surfaceID = uuid(params, "surface_id") {
            context?.controlBrowserRecordUnsupportedRequest(
                surfaceID: surfaceID,
                request: .object(["action": .string("route"), "params": .object(params)])
            )
        }
        return browserNotSupported(
            "browser.network.route",
            details: "WKWebView does not provide CDP-style request interception/mocking"
        )
    }

    /// `browser.network.unroute` — record the attempt, then `not_supported`.
    func browserNetworkUnroute(_ params: [String: JSONValue]) -> ControlCallResult {
        if let surfaceID = uuid(params, "surface_id") {
            context?.controlBrowserRecordUnsupportedRequest(
                surfaceID: surfaceID,
                request: .object(["action": .string("unroute"), "params": .object(params)])
            )
        }
        return browserNotSupported(
            "browser.network.unroute",
            details: "WKWebView does not provide CDP-style request interception/mocking"
        )
    }

    /// `browser.network.requests` — `not_supported`, carrying the recorded
    /// attempts when a surface is given.
    func browserNetworkRequests(_ params: [String: JSONValue]) -> ControlCallResult {
        if let surfaceID = uuid(params, "surface_id") {
            let items = context?.controlBrowserUnsupportedRequests(surfaceID: surfaceID) ?? []
            return .err(
                code: "not_supported",
                message: "browser.network.requests is not supported on WKWebView",
                data: .object([
                    "details": .string("Request interception logs are unavailable without CDP network hooks"),
                    "recorded_requests": .array(items),
                ])
            )
        }
        return browserNotSupported(
            "browser.network.requests",
            details: "Request interception logs are unavailable without CDP network hooks"
        )
    }
}
