import Foundation
import WebKit

extension BrowserAutomationController {
    /// Resolves a `browser.eval` request: evaluates the user `script` against the
    /// live browser surface (through the host's worker-lane JS-eval seam) and
    /// shapes the workspace/surface refs plus the normalized result value, flagging
    /// an isolated-content-world fallback when page-world eval was CSP-blocked.
    ///
    /// Byte-faithful lift of the former `TerminalController.v2BrowserEval` body: the
    /// panel resolution hops to the main actor inside ``BrowserControlHosting``, the
    /// required-`script` guard and value normalization stay here on the worker lane,
    /// and the JS evaluation runs through the host's eval seam.
    ///
    /// `nonisolated`: runs on the socket worker lane (the JS evaluation blocks
    /// there); the only main-actor hops are inside the host witnesses.
    public nonisolated func browserEval(
        params: [String: Any],
        host: any BrowserControlHosting
    ) -> BrowserCommandResult {
        guard let script = Self.stringParam(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return host.withBrowserPanelContext(params: params) { ctx in
            var usedIsolatedWorld = false
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceID,
                script: script,
                timeout: 10.0,
                useEval: true,
                onIsolatedWorldFallback: { usedIsolatedWorld = true }
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceID.uuidString,
                    "workspace_ref": host.v2Ref(kind: .workspace, uuid: ctx.workspaceID),
                    "surface_id": ctx.surfaceID.uuidString,
                    "surface_ref": host.v2Ref(kind: .surface, uuid: ctx.surfaceID),
                    "value": normalizeJSValue(value)
                ]
                if usedIsolatedWorld {
                    // Page-world eval was blocked (typically CSP without 'unsafe-eval'); this value
                    // came from the isolated content world. It shares the DOM but cannot read
                    // page-world JS globals, so flag it instead of returning silently.
                    payload["content_world"] = "isolated"
                    payload["content_world_note"] = "Page-world eval was blocked (likely CSP without 'unsafe-eval'); value came from the isolated content world, which shares the DOM but cannot see page-world JS globals."
                }
                return .ok(payload)
            }
        }
    }

    /// Resolves a `browser.snapshot` request: builds the in-page DOM-walk script
    /// from the request flags, evaluates it against the live surface (through the
    /// host's worker-lane JS-eval seam), allocates element refs, and shapes the
    /// accessibility-tree text + per-ref metadata payload.
    ///
    /// Byte-faithful lift of the former `TerminalController.v2BrowserSnapshot` body.
    /// The pure DOM-walk script assembly lives in
    /// ``BrowserControlService/snapshotScript(interactiveLiteral:cursorLiteral:compactLiteral:maxDepth:scopeLiteral:)``;
    /// the WebKit evaluation, element-ref allocation, and tree-line/payload shaping
    /// stay here on the socket-worker lane.
    ///
    /// The host's `v2BrowserSnapshot` witness (which the post-action snapshot path
    /// reaches through ``appendPostSnapshot(params:surfaceId:payload:host:)``)
    /// forwards into this method.
    ///
    /// `nonisolated`: runs on the socket worker lane; the panel resolution and JS
    /// evaluation hop to the main actor inside the host witnesses.
    public nonisolated func browserSnapshot(
        params: [String: Any],
        host: any BrowserControlHosting
    ) -> BrowserCommandResult {
        let interactiveOnly = Self.boolParam(params, "interactive") ?? false
        let includeCursor = Self.boolParam(params, "cursor") ?? false
        let compact = Self.boolParam(params, "compact") ?? false
        let maxDepth = max(0, Self.intParam(params, "max_depth") ?? Self.intParam(params, "maxDepth") ?? 12)
        let scopeSelector = Self.stringParam(params, "selector")

        return host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(jsonLiteral) ?? "null"

            let script = control.snapshotScript(
                interactiveLiteral: interactiveLiteral,
                cursorLiteral: cursorLiteral,
                compactLiteral: compactLiteral,
                maxDepth: maxDepth,
                scopeLiteral: scopeLiteral
            )

            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: surfaceId,
                script: script,
                timeout: 10.0,
                useEval: false,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = allocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceID.uuidString,
                    "workspace_ref": host.v2Ref(kind: .workspace, uuid: ctx.workspaceID),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": host.v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    /// Resolves a `browser.wait` request: builds the condition expression from the
    /// request's param precedence (a resolved selector, else
    /// url_contains > text_contains > load_state > function > default-ready), waits
    /// for it to become truthy against the live surface (through the host's
    /// worker-lane wait seam), and shapes the met/timeout/eval-failed result.
    ///
    /// Byte-faithful lift of the former `TerminalController.v2BrowserWait` body. The
    /// condition-script assembly lives in ``BrowserControlService`` wait builders;
    /// the param-precedence resolution and selector resolution stay here on the
    /// worker lane, exactly as before. The former inline panel resolution (which was
    /// an identical copy of `v2BrowserWithPanelContext`) now routes through the
    /// shared ``BrowserControlHosting/withBrowserPanelContext(params:_:)`` seam head.
    ///
    /// `nonisolated`: runs on the socket worker lane (the wait blocks there); the
    /// panel resolution and the failed-condition `url` read hop to the main actor
    /// inside the host witness / ``runMainSync(_:)``.
    public nonisolated func browserWait(
        params: [String: Any],
        host: any BrowserControlHosting
    ) -> BrowserCommandResult {
        let timeoutMs = max(1, Self.intParam(params, "timeout_ms") ?? 5_000)
        let selectorRaw = selector(in: params)

        // The condition expressions are built by CmuxBrowser's
        // ``BrowserControlService`` wait-script builders; only the byte-identical
        // string assembly moved there. The param-precedence resolution
        // (url_contains > text_contains > load_state > function > default) stays
        // here, exactly as before.
        let conditionScriptBase: String = {
            if let urlContains = Self.stringParam(params, "url_contains") {
                return control.waitURLContainsScript(substring: urlContains)
            }
            if let textContains = Self.stringParam(params, "text_contains") {
                return control.waitTextContainsScript(substring: textContains)
            }
            if let loadState = Self.stringParam(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return control.waitLoadStateInteractiveScript()
                }
                return control.waitLoadStateScript(normalizedLoadState: normalizedLoadState)
            }
            if let fn = Self.stringParam(params, "function") {
                return control.waitFunctionScript(function: fn)
            }
            return control.waitDefaultReadyScript()
        }()

        return host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            let webView = ctx.webView
            let workspaceId = ctx.workspaceID

            let conditionScript: String
            if let selectorRaw {
                guard let selector = resolveSelector(selectorRaw, surfaceId: surfaceId) else {
                    return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
                }
                conditionScript = control.waitSelectorPresentScript(selector: selector)
            } else {
                conditionScript = conditionScriptBase
            }

            switch host.v2WaitForBrowserCondition(
                webView,
                surfaceId: surfaceId,
                conditionScript: conditionScript,
                timeoutMs: timeoutMs
            ) {
            case .met:
                return .ok([
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": host.v2Ref(kind: .workspace, uuid: workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": host.v2Ref(kind: .surface, uuid: surfaceId),
                    "waited": true
                ])
            case .timedOut:
                return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
            case .evaluationFailed(let message):
                return .err(
                    code: "js_error",
                    message: "Wait condition could not be evaluated: \(message)",
                    data: [
                        "timeout_ms": timeoutMs,
                        "url": runMainSync { webView.url?.absoluteString ?? "about:blank" },
                        "hint": "Verify the page loaded with 'cmux browser <surface> get url' before waiting"
                    ]
                )
            }
        }
    }
}
