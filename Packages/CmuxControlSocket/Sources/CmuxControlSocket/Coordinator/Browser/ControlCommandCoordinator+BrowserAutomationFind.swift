internal import Foundation

/// The browser element-finder bodies (`browser.find.*`) and frame selection
/// (`browser.frame.select` / `browser.frame.main`), with their injected JS
/// byte-identical to the legacy `v2BrowserFind*` / `v2BrowserFrame*`
/// originals.
extension ControlCommandCoordinator {
    /// Runs a finder body inside the shared CSS-path wrapper, mints an `@eN`
    /// element ref for the match, and shapes the standard find payload (twin
    /// of `v2BrowserFindWithScript`).
    private func browserFindWithScript(
        _ params: [String: JSONValue],
        actionName: String,
        finderBody: String,
        metadata: [String: JSONValue] = [:]
    ) -> ControlCallResult {
        return withBrowserPanel(params) { workspaceID, surfaceID in
            let script = """
            (() => {
              const __cmuxCssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
                  if (siblings.length > 1) {
                    const pos = siblings.indexOf(cur) + 1;
                    part += `:nth-of-type(${pos})`;
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                }
                return parts.join(' > ');
              };

              const __cmuxFound = (() => {
            \(finderBody)
              })();
              if (!__cmuxFound) return { ok: false, error: 'not_found' };
              const selector = __cmuxCssPath(__cmuxFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__cmuxFound.tagName || '').toLowerCase(),
                text: String(__cmuxFound.textContent || '').trim()
              };
            })()
            """

            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: .object(["action": .string(actionName)]))
            case .success(let value):
                guard let dict = browserScriptObject(value),
                      browserExactBool(dict["ok"]) == true,
                      let selector = browserStringValue(dict["selector"]),
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: .object(metadata))
                }

                let elementRef = browserContext?.controlBrowserAutomationState
                    .allocateElementRef(surfaceID: surfaceID, selector: selector) ?? ""
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["action"] = .string(actionName)
                payload["selector"] = .string(selector)
                payload["element_ref"] = .string(elementRef)
                payload["ref"] = .string(elementRef)
                for (key, metadataValue) in metadata {
                    payload[key] = metadataValue
                }
                if let tag = browserStringValue(dict["tag"]) {
                    payload["tag"] = .string(tag)
                }
                if let text = browserStringValue(dict["text"]) {
                    payload["text"] = .string(text)
                }
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.find.role` — find by ARIA role (explicit or implicit) and
    /// optional accessible name.
    func browserFindRole(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let role = (string(params, "role") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = string(params, "name")?.lowercased()
        let exact = bool(params, "exact") ?? false
        let roleLiteral = browserJSONLiteral(role)
        let nameLiteral = name.map(browserJSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.role",
            finderBody: finder,
            metadata: [
                "role": .string(role),
                "name": orNull(name),
                "exact": .bool(exact),
            ]
        )
    }

    /// `browser.find.text` — find by (normalized) text content.
    func browserFindText(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let text = (string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        let textLiteral = browserJSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": .string(text), "exact": .bool(exact)]
        )
    }

    /// `browser.find.label` — find the control a `<label>` points at.
    func browserFindLabel(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let label = (string(params, "label") ?? string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        let labelLiteral = browserJSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return browserFindWithScript(
            params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": .string(label), "exact": .bool(exact)]
        )
    }

    /// `browser.find.placeholder` — find by placeholder text.
    func browserFindPlaceholder(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let placeholder = (string(params, "placeholder") ?? string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        let placeholderLiteral = browserJSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": .string(placeholder), "exact": .bool(exact)]
        )
    }

    /// `browser.find.alt` — find by `alt` text.
    func browserFindAlt(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let alt = (string(params, "alt") ?? string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        let altLiteral = browserJSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": .string(alt), "exact": .bool(exact)]
        )
    }

    /// `browser.find.title` — find by `title` attribute.
    func browserFindTitle(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let title = (string(params, "title") ?? string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        let titleLiteral = browserJSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": .string(title), "exact": .bool(exact)]
        )
    }

    /// `browser.find.testid` — find by `data-testid`-style attributes.
    func browserFindTestId(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let testId = string(params, "testid") ?? string(params, "test_id") ?? string(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = browserJSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return browserFindWithScript(
            params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": .string(testId)]
        )
    }

    /// `browser.find.first` — pin the first match of a selector.
    func browserFindFirst(_ params: [String: JSONValue]) -> ControlCallResult {
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
            let selectorLiteral = browserJSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = browserScriptObject(value),
                      browserExactBool(dict["ok"]) == true else {
                    return .err(
                        code: "not_found",
                        message: "Element not found",
                        data: .object(["selector": .string(selector)])
                    )
                }
                let elementRef = browserContext?.controlBrowserAutomationState
                    .allocateElementRef(surfaceID: surfaceID, selector: selector) ?? ""
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["selector"] = .string(selector)
                payload["element_ref"] = .string(elementRef)
                payload["ref"] = .string(elementRef)
                payload["text"] = dict["text"] ?? .null
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.find.last` — pin the last match of a selector.
    func browserFindLast(_ params: [String: JSONValue]) -> ControlCallResult {
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
            let selectorLiteral = browserJSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = browserScriptObject(value),
                      browserExactBool(dict["ok"]) == true,
                      let finalSelector = browserStringValue(dict["selector"]),
                      !finalSelector.isEmpty else {
                    return .err(
                        code: "not_found",
                        message: "Element not found",
                        data: .object(["selector": .string(selector)])
                    )
                }
                let elementRef = browserContext?.controlBrowserAutomationState
                    .allocateElementRef(surfaceID: surfaceID, selector: finalSelector) ?? ""
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["selector"] = .string(finalSelector)
                payload["element_ref"] = .string(elementRef)
                payload["ref"] = .string(elementRef)
                payload["text"] = dict["text"] ?? .null
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.find.nth` — pin the nth match of a selector (negative wraps
    /// from the end).
    func browserFindNth(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let selectorRaw = browserSelectorParam(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = int(params, "index") ?? int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
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
            let selectorLiteral = browserJSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const nth = idx + 1;
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${nth})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = browserScriptObject(value),
                      browserExactBool(dict["ok"]) == true,
                      let finalSelector = browserStringValue(dict["selector"]),
                      !finalSelector.isEmpty else {
                    return .err(
                        code: "not_found",
                        message: "Element not found",
                        data: .object(["selector": .string(selector), "index": .int(Int64(index))])
                    )
                }
                let elementRef = browserContext?.controlBrowserAutomationState
                    .allocateElementRef(surfaceID: surfaceID, selector: finalSelector) ?? ""
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["selector"] = .string(finalSelector)
                payload["element_ref"] = .string(elementRef)
                payload["ref"] = .string(elementRef)
                payload["index"] = dict["index"] ?? .null
                payload["text"] = dict["text"] ?? .null
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.frame.select` — scope subsequent commands to a same-origin
    /// iframe.
    func browserFrameSelect(_ params: [String: JSONValue]) -> ControlCallResult {
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
            let selectorLiteral = browserJSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = browserScriptObject(value),
                   browserExactBool(dict["ok"]) == true {
                    browserContext?.controlBrowserAutomationState
                        .setFrameSelector(selector, forSurface: surfaceID)
                    var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                    payload["frame_selector"] = .string(selector)
                    return .ok(.object(payload))
                }
                if let dict = browserScriptObject(value),
                   browserStringValue(dict["error"]) == "cross_origin" {
                    return .err(
                        code: "not_supported",
                        message: "Cross-origin iframe control is not supported",
                        data: .object(["selector": .string(selector)])
                    )
                }
                return .err(
                    code: "not_found",
                    message: "Frame not found",
                    data: .object(["selector": .string(selector)])
                )
            }
        }
    }

    /// `browser.frame.main` — return to the main frame.
    func browserFrameMain(_ params: [String: JSONValue]) -> ControlCallResult {
        return withBrowserPanel(params) { workspaceID, surfaceID in
            browserContext?.controlBrowserAutomationState.setFrameSelector(nil, forSurface: surfaceID)
            var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            payload["frame_selector"] = .null
            return .ok(.object(payload))
        }
    }
}
