internal import Foundation

/// The browser DOM-automation domain (element refs, JS eval, dialogs,
/// frames), lifted byte-faithfully from the former `TerminalController`
/// `v2Browser*` bodies. Script strings, retry/wait loops, payload shapes, and
/// every error code/message are identical; only the WKWebView reach (JS
/// execution, snapshot capture, user-script injection, dialog completion
/// handlers) crosses the ``ControlBrowserAutomationContext`` seam.
extension ControlCommandCoordinator {
    /// Dispatches the browser DOM-automation methods this coordinator owns;
    /// returns `nil` for anything else (including the nav/tab/network browser
    /// methods) so the core `handle(_:)` can fall through.
    func handleBrowserAutomation(_ request: ControlRequest) -> ControlCallResult? {
        let params = request.params
        switch request.method {
        case "browser.eval":
            return browserEval(params)
        case "browser.wait":
            return browserWait(params)
        case "browser.click":
            return browserClick(params)
        case "browser.dblclick":
            return browserDblClick(params)
        case "browser.hover":
            return browserHover(params)
        case "browser.focus":
            return browserFocusElement(params)
        case "browser.type":
            return browserType(params)
        case "browser.fill":
            return browserFill(params)
        case "browser.press":
            return browserPress(params)
        case "browser.keydown":
            return browserKeyDown(params)
        case "browser.keyup":
            return browserKeyUp(params)
        case "browser.check":
            return browserCheck(params, checked: true)
        case "browser.uncheck":
            return browserCheck(params, checked: false)
        case "browser.select":
            return browserSelect(params)
        case "browser.scroll":
            return browserScroll(params)
        case "browser.scroll_into_view":
            return browserScrollIntoView(params)
        case "browser.screenshot":
            return browserScreenshot(params)
        case "browser.get.text":
            return browserGetText(params)
        case "browser.get.html":
            return browserGetHTML(params)
        case "browser.get.value":
            return browserGetValue(params)
        case "browser.get.attr":
            return browserGetAttr(params)
        case "browser.get.title":
            return browserGetTitle(params)
        case "browser.get.count":
            return browserGetCount(params)
        case "browser.get.box":
            return browserGetBox(params)
        case "browser.get.styles":
            return browserGetStyles(params)
        case "browser.is.visible":
            return browserIsVisible(params)
        case "browser.is.enabled":
            return browserIsEnabled(params)
        case "browser.is.checked":
            return browserIsChecked(params)
        case "browser.find.role":
            return browserFindRole(params)
        case "browser.find.text":
            return browserFindText(params)
        case "browser.find.label":
            return browserFindLabel(params)
        case "browser.find.placeholder":
            return browserFindPlaceholder(params)
        case "browser.find.alt":
            return browserFindAlt(params)
        case "browser.find.title":
            return browserFindTitle(params)
        case "browser.find.testid":
            return browserFindTestId(params)
        case "browser.find.first":
            return browserFindFirst(params)
        case "browser.find.last":
            return browserFindLast(params)
        case "browser.find.nth":
            return browserFindNth(params)
        case "browser.frame.select":
            return browserFrameSelect(params)
        case "browser.frame.main":
            return browserFrameMain(params)
        case "browser.dialog.accept":
            return browserDialogRespond(params, accept: true)
        case "browser.dialog.dismiss":
            return browserDialogRespond(params, accept: false)
        case "browser.highlight":
            return browserHighlight(params)
        case "browser.addinitscript":
            return browserAddInitScript(params)
        case "browser.addscript":
            return browserAddScript(params)
        case "browser.addstyle":
            return browserAddStyle(params)
        default:
            return nil
        }
    }

    /// The browser-automation view of the seam. Once the integrator adds
    /// ``ControlBrowserAutomationContext`` to the ``ControlCommandContext``
    /// umbrella this cast is statically guaranteed (and may be simplified to
    /// `context`); until then it lets the domain build standalone without
    /// touching the integrator-owned umbrella file.
    var browserContext: (any ControlBrowserAutomationContext)? {
        context as? any ControlBrowserAutomationContext
    }

    // MARK: - Panel resolution (twin of v2BrowserWithPanel)

    /// Resolves the target browser panel and runs `body` against it,
    /// translating each ``ControlBrowserPanelResolution`` failure into the
    /// exact legacy error.
    func withBrowserPanel(
        _ params: [String: JSONValue],
        _ body: (_ workspaceID: UUID, _ surfaceID: UUID) -> ControlCallResult
    ) -> ControlCallResult {
        let resolution = browserContext?.controlBrowserResolvePanel(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id") ?? uuid(params, "tab_id")
        ) ?? .tabManagerUnavailable
        guard case .resolved(let workspaceID, let surfaceID) = resolution else {
            return browserPanelResolutionError(resolution)
        }
        return body(workspaceID, surfaceID)
    }

    /// The legacy error for each non-resolved panel-resolution outcome.
    func browserPanelResolutionError(_ resolution: ControlBrowserPanelResolution) -> ControlCallResult {
        switch resolution {
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
        case .resolved:
            return .err(code: "internal_error", message: "Browser operation failed", data: nil)
        }
    }

    // MARK: - Script plumbing

    /// Runs a frame-scoped automation script through the seam (the legacy
    /// `v2RunBrowserJavaScript` call shape, defaults included).
    func browserRunScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> ControlBrowserScriptOutcome {
        browserContext?.controlBrowserRunAutomationScript(
            surfaceID: surfaceID,
            script: script,
            timeout: timeout,
            useEval: useEval
        ) ?? .failure("Browser operation failed")
    }

    /// The selector param accepted by element commands (was
    /// `v2BrowserSelector`): `selector` / `sel` / `element_ref` / `ref`.
    func browserSelectorParam(_ params: [String: JSONValue]) -> String? {
        string(params, "selector")
            ?? string(params, "sel")
            ?? string(params, "element_ref")
            ?? string(params, "ref")
    }

    /// A string embedded as a JSON literal for interpolation into a script
    /// (was `v2JSONLiteral`, whose call sites in this domain all pass
    /// strings).
    func browserJSONLiteral(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    // MARK: - Bridged-result casts (legacy `as?` semantics on JSONValue)

    /// The object payload of a bridged script value (the legacy
    /// `value as? [String: Any]`).
    func browserScriptObject(_ value: ControlBrowserScriptValue) -> [String: JSONValue]? {
        guard case .value(.object(let dict)) = value else { return nil }
        return dict
    }

    /// The legacy `NSNumber as? Bool` bridge: `true`/`false` for booleans and
    /// for numbers exactly equal to 1/0; otherwise `nil`.
    func browserExactBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag):
            return flag
        case .int(let number):
            if number == 0 { return false }
            if number == 1 { return true }
            return nil
        case .double(let number):
            if number == 0 { return false }
            if number == 1 { return true }
            return nil
        default:
            return nil
        }
    }

    /// The legacy `(value as? NSNumber)?.intValue` bridge (booleans count as
    /// 1/0, doubles truncate toward zero via `NSNumber.intValue`).
    func browserNumberInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let number):
            return Int(number)
        case .double(let number):
            return NSNumber(value: number).intValue
        case .bool(let flag):
            return NSNumber(value: flag).intValue
        default:
            return nil
        }
    }

    /// The legacy `value as? String` bridge.
    func browserStringValue(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    /// The wire payload for a bridged script value (the legacy
    /// `v2NormalizeJSValue` result): `undefined` re-encodes as the eval
    /// envelope, exactly as before.
    func browserPayloadValue(_ value: ControlBrowserScriptValue) -> JSONValue {
        switch value {
        case .undefined:
            return .object([
                ControlBrowserScriptValue.envelopeTypeKey:
                    .string(ControlBrowserScriptValue.envelopeTypeUndefined),
                ControlBrowserScriptValue.envelopeValueKey: .null,
            ])
        case .value(let jsonValue):
            return jsonValue
        }
    }

    // MARK: - Wait plumbing (twin of v2WaitForBrowserCondition)

    /// Polls a JS condition with mutation observers and navigation listeners
    /// until it holds or the timeout fires (script byte-identical to the
    /// legacy `v2WaitForBrowserCondition`).
    func browserWaitForCondition(
        surfaceID: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch browserRunScript(
            surfaceID: surfaceID,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            guard case .value(let jsonValue) = value else { return false }
            return browserExactBool(jsonValue) == true
        case .failure:
            return false
        }
    }

    // MARK: - Not-found diagnostics (twins of v2BrowserNotFoundDiagnostics / v2BrowserElementNotFoundResult)

    /// Collects selector diagnostics for an element-not-found error (script
    /// and output keys byte-identical to `v2BrowserNotFoundDiagnostics`).
    func browserNotFoundDiagnostics(
        surfaceID: UUID,
        selector: String
    ) -> [String: JSONValue] {
        let selectorLiteral = browserJSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch browserRunScript(surfaceID: surfaceID, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": .string(selector),
                "diagnostics_error": .string(message),
            ]
        case .success(let value):
            guard let dict = browserScriptObject(value) else {
                return ["selector": .string(selector)]
            }
            var out: [String: JSONValue] = ["selector": .string(selector)]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = sample }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    /// Builds the legacy element-not-found error (message selection and data
    /// keys identical to `v2BrowserElementNotFoundResult`).
    func browserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceID: UUID
    ) -> ControlCallResult {
        var data = browserNotFoundDiagnostics(surfaceID: surfaceID, selector: selector)
        data["action"] = .string(actionName)
        data["retry_attempts"] = .int(Int64(attempts))
        data["hint"] = .string("Run 'browser snapshot' to refresh refs, then retry with a more specific selector.")

        let count = browserNumberInt(data["match_count"]) ?? 0
        let visibleCount = browserNumberInt(data["visible_match_count"]) ?? 0

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: .object(data))
    }

    // MARK: - Selector action loop (twin of v2BrowserSelectorAction)

    /// Resolves the selector, runs the action script with the legacy retry +
    /// appear-wait loop, and shapes the standard action payload.
    func browserSelectorAction(
        _ params: [String: JSONValue],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> ControlCallResult {
        guard let selectorRaw = browserSelectorParam(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return withBrowserPanel(params) { workspaceID, surfaceID in
            guard let selector = browserContext?.controlBrowserAutomationState
                .resolveSelector(selectorRaw, surfaceID: surfaceID) else {
                return .err(
                    code: "not_found",
                    message: "Element reference not found",
                    data: .object(["selector": .string(selectorRaw)])
                )
            }
            let script = scriptBuilder(browserJSONLiteral(selector))
            let retryAttempts = max(1, int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(browserJSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch browserRunScript(surfaceID: surfaceID, script: script, useEval: false) {
                case .failure(let message):
                    return .err(
                        code: "js_error",
                        message: message,
                        data: .object(["action": .string(actionName), "selector": .string(selector)])
                    )
                case .success(let value):
                    if let dict = browserScriptObject(value),
                       browserExactBool(dict["ok"]) == true {
                        var payload: [String: JSONValue] = [
                            "workspace_id": .string(workspaceID.uuidString),
                            "surface_id": .string(surfaceID.uuidString),
                            "action": .string(actionName),
                            "attempts": .int(Int64(attempt)),
                        ]
                        payload["workspace_ref"] = ref(.workspace, workspaceID)
                        payload["surface_ref"] = ref(.surface, surfaceID)
                        if let resultValue = dict["value"] {
                            payload["value"] = resultValue
                        }
                        browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
                        return .ok(.object(payload))
                    }

                    let errorText = browserScriptObject(value).flatMap { browserStringValue($0["error"]) }
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard browserWaitForCondition(
                            surfaceID: surfaceID,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return browserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceID: surfaceID
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return browserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceID: surfaceID
                        )
                    }

                    return .err(
                        code: "js_error",
                        message: "Browser action failed",
                        data: .object(["action": .string(actionName), "selector": .string(selector)])
                    )
                }
            }

            return browserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceID: surfaceID
            )
        }
    }

    /// The standard workspace/surface identity payload most browser bodies
    /// open with.
    func browserIdentityPayload(workspaceID: UUID, surfaceID: UUID) -> [String: JSONValue] {
        [
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": ref(.surface, surfaceID),
        ]
    }
}
