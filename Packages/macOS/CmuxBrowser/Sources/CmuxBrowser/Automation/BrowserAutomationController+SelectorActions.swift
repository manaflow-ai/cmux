import Foundation

extension BrowserAutomationController {
    /// The shared retry body for every `browser.*` selector action (the getters,
    /// the predicates, and the interaction commands): resolves the panel context
    /// through the host, resolves the selector/element-ref in-package, runs the
    /// command's `scriptBuilder` script against the live `WKWebView` through the
    /// host's worker-lane JS-eval seam, and retries on a transient `not_found`
    /// (waiting for the selector to appear between attempts) before producing the
    /// success payload or the diagnostic `not_found` result.
    ///
    /// `nonisolated`: runs on the socket worker lane. The panel resolution and the
    /// JS evaluation hop to the main actor inside the host witnesses; the
    /// selector resolution, element-ref reads, value normalization, and post-action
    /// snapshot are pure per-surface-state or stateless-substrate work owned here.
    public nonisolated func selectorAction(
        params: [String: Any],
        actionName: String,
        host: any BrowserControlHosting,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> BrowserCommandResult {
        guard let selectorRaw = selector(in: params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            guard let selector = resolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(jsonLiteral(selector))
            let retryAttempts = max(1, Self.intParam(params, "retry_attempts") ?? 3)
            // Pure script assembly lives in `BrowserControlService`, shared with the
            // `v2BrowserWait` resolved-selector branch; the WebKit evaluation in
            // ``BrowserControlHosting/v2WaitForBrowserCondition`` stays on the worker
            // lane.
            let selectorCondition = control.waitSelectorPresentScript(selector: selector)

            for attempt in 1...retryAttempts {
                switch host.v2RunBrowserJavaScript(
                    ctx.webView,
                    surfaceId: surfaceId,
                    script: script,
                    timeout: 5.0,
                    useEval: false,
                    onIsolatedWorldFallback: nil
                ) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ctx.workspaceID.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = host.v2Ref(kind: .workspace, uuid: ctx.workspaceID)
                        payload["surface_ref"] = host.v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = normalizeJSValue(resultValue)
                        }
                        appendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload, host: host)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard case .met = host.v2WaitForBrowserCondition(
                            ctx.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return browserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                webView: ctx.webView,
                                host: host
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return browserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            webView: ctx.webView,
                            host: host
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return browserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                webView: ctx.webView,
                host: host
            )
        }
    }

    // MARK: - Getters

    /// The `browser.get.text` getter: returns the target element's text content.
    public nonisolated func getText(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "get.text", host: host) { selectorLiteral in
            control.getTextScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.get.html` getter: returns the target element's inner HTML.
    public nonisolated func getHTML(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "get.html", host: host) { selectorLiteral in
            control.getHTMLScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.get.value` getter: returns the target form element's value.
    public nonisolated func getValue(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "get.value", host: host) { selectorLiteral in
            control.getValueScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.get.attr` getter: returns the named attribute's value. The
    /// required `attr`/`name` param is validated before the panel head, exactly
    /// like the legacy body.
    public nonisolated func getAttr(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        guard let attr = Self.stringParam(params, "attr") ?? Self.stringParam(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return selectorAction(params: params, actionName: "get.attr", host: host) { selectorLiteral in
            control.getAttrScript(selectorLiteral: selectorLiteral, attrLiteral: jsonLiteral(attr))
        }
    }

    /// The `browser.get.count` getter: returns the count of elements matching the
    /// selector. Unlike the other getters it does not retry; it runs the count
    /// script once against the resolved panel.
    public nonisolated func getCount(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        guard let selectorRaw = selector(in: params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            guard let selector = resolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = control.getCountScript(selectorLiteral: jsonLiteral(selector))
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: surfaceId,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ctx.workspaceID.uuidString,
                    "workspace_ref": host.v2Ref(kind: .workspace, uuid: ctx.workspaceID),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": host.v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    /// The `browser.get.box` getter: returns the target element's bounding box.
    public nonisolated func getBox(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "get.box", host: host) { selectorLiteral in
            control.getBoxScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.get.styles` getter: returns a single computed `property` when
    /// given, otherwise a summary of the target element's computed styles.
    public nonisolated func getStyles(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        let property = Self.stringParam(params, "property")
        return selectorAction(params: params, actionName: "get.styles", host: host) { selectorLiteral in
            if let property {
                return control.getStylesPropertyScript(
                    selectorLiteral: selectorLiteral,
                    propertyLiteral: jsonLiteral(property)
                )
            }
            return control.getStylesSummaryScript(selectorLiteral: selectorLiteral)
        }
    }

    // MARK: - Predicates

    /// The `browser.is.visible` predicate.
    public nonisolated func isVisible(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "is.visible", host: host) { selectorLiteral in
            control.isVisibleScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.is.enabled` predicate.
    public nonisolated func isEnabled(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "is.enabled", host: host) { selectorLiteral in
            control.isEnabledScript(selectorLiteral: selectorLiteral)
        }
    }

    /// The `browser.is.checked` predicate.
    public nonisolated func isChecked(params: [String: Any], host: any BrowserControlHosting) -> BrowserCommandResult {
        selectorAction(params: params, actionName: "is.checked", host: host) { selectorLiteral in
            control.isCheckedScript(selectorLiteral: selectorLiteral)
        }
    }
}
