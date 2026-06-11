internal import Foundation

/// Browser domain, part 3: the accessibility-style page snapshot and the
/// cookie/storage commands. See `+Browser.swift` for the dispatch.
extension ControlCommandCoordinator {
    // MARK: - snapshot

    /// `browser.snapshot` — the role/name/ref page snapshot. The script and
    /// shaping are byte-faithful to the legacy `v2BrowserSnapshot`; element
    /// refs are minted through the seam into the shared app-side registry.
    func browserSnapshot(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let interactiveOnly = bool(params, "interactive") ?? false
        let includeCursor = bool(params, "cursor") ?? false
        let compact = bool(params, "compact") ?? false
        let maxDepth = max(0, int(params, "max_depth") ?? int(params, "maxDepth") ?? 12)
        let scopeSelector = string(params, "selector")

        let interactiveLiteral = interactiveOnly ? "true" : "false"
        let cursorLiteral = includeCursor ? "true" : "false"
        let compactLiteral = compact ? "true" : "false"
        let scopeLiteral = scopeSelector.map { browserJSONLiteral(.string($0)) } ?? "null"

        let script = """
        (() => {
          const __interactiveOnly = \(interactiveLiteral);
          const __includeCursor = \(cursorLiteral);
          const __compact = \(compactLiteral);
          const __maxDepth = \(maxDepth);
          const __scopeSelector = \(scopeLiteral);

          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
          const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
          const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

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

          const __implicitRole = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            if (tag === 'button') return 'button';
            if (tag === 'a' && el.hasAttribute('href')) return 'link';
            if (tag === 'input') {
              const type = String(el.getAttribute('type') || 'text').toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
              return 'textbox';
            }
            if (tag === 'textarea') return 'textbox';
            if (tag === 'select') return 'combobox';
            if (tag === 'summary') return 'button';
            if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
            if (tag === 'li') return 'listitem';
            return null;
          };

          const __nameFor = (el) => {
            const aria = __normalize(el.getAttribute('aria-label') || '');
            if (aria) return aria;
            const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
            if (labelledBy) {
              const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
              if (text) return text;
            }
            if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
              const placeholder = __normalize(el.getAttribute('placeholder') || '');
              if (placeholder) return placeholder;
              const value = __normalize(el.value || '');
              if (value) return value;
            }
            const title = __normalize(el.getAttribute('title') || '');
            if (title) return title;
            const text = __normalize(el.innerText || el.textContent || '');
            if (text) return text.slice(0, 120);
            return '';
          };

          const __cssPath = (el) => {
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
              const parent = cur.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                if (siblings.length > 1) {
                  const index = siblings.indexOf(cur) + 1;
                  part += `:nth-of-type(${index})`;
                }
              }
              parts.unshift(part);
              cur = cur.parentElement;
              if (parts.length >= 6) break;
            }
            return parts.join(' > ');
          };

          const __root = (() => {
            if (__scopeSelector) {
              return document.querySelector(__scopeSelector) || document.body || document.documentElement;
            }
            return document.body || document.documentElement;
          })();

          const __entries = [];
          const __seen = new Set();
          const __appendEntry = (el, depth, forcedRole) => {
            if (!__isVisible(el)) return;
            const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
            const role = forcedRole || explicitRole || __implicitRole(el) || '';
            if (!role) return;

            if (__interactiveOnly && !__interactiveRoles.has(role)) return;
            if (!__interactiveOnly) {
              const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
              if (!includeRole) return;
              if (__compact && __structuralRoles.has(role)) {
                const name = __nameFor(el);
                if (!name) return;
              }
            }

            const selector = __cssPath(el);
            if (!selector || __seen.has(selector)) return;
            __seen.add(selector);
            __entries.push({
              selector,
              role,
              name: __nameFor(el),
              depth
            });
          };

          const __walk = (node, depth) => {
            if (!node || depth > __maxDepth || node.nodeType !== 1) return;
            const el = node;
            __appendEntry(el, depth, null);
            for (const child of Array.from(el.children || [])) {
              __walk(child, depth + 1);
            }
          };

          if (__root) {
            __walk(__root, 0);
          }

          if (__includeCursor && __root) {
            const all = Array.from(__root.querySelectorAll('*'));
            for (const el of all) {
              if (!__isVisible(el)) continue;
              const style = getComputedStyle(el);
              const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
              const hasCursorPointer = style.cursor === 'pointer';
              const tabIndex = el.getAttribute('tabindex');
              const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
              if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
              __appendEntry(el, 0, 'generic');
              if (__entries.length >= 256) break;
            }
          }

          const body = document.body;
          const root = document.documentElement;
          return {
            title: __normalize(document.title || ''),
            url: String(location.href || ''),
            ready_state: String(document.readyState || ''),
            text: body ? String(body.innerText || '') : '',
            html: root ? String(root.outerHTML || '') : '',
            entries: __entries
          };
        })()
        """

        switch context.controlBrowserRunScript(
            target: browserSurfaceTarget(params),
            script: script,
            timeout: 10.0,
            mode: .frameAware(useEval: false)
        ) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .resolved(let identity, let outcome):
            switch outcome {
            case .jsError(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .undefined:
                return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
            case .value(let value):
                guard case .object(let dict) = value else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }
                return browserSnapshotPayload(dict: dict, identity: identity, context: context)
            }
        }
    }

    /// Shapes the snapshot payload from the page readout (the second half of
    /// the legacy `v2BrowserSnapshot` closure).
    private func browserSnapshotPayload(
        dict: [String: JSONValue],
        identity: ControlBrowserPanelIdentity,
        context: any ControlCommandContext
    ) -> ControlCallResult {
        let title = browserStringField(dict["title"]) ?? ""
        let url = browserStringField(dict["url"]) ?? ""
        let readyState = browserStringField(dict["ready_state"]) ?? ""
        let text = browserStringField(dict["text"]) ?? ""
        let html = browserStringField(dict["html"]) ?? ""
        let entries = browserObjectArrayField(dict["entries"])

        var refs: [String: JSONValue] = [:]
        var treeLines: [String] = []
        var seenSelectors: Set<String> = []

        for entry in entries {
            guard let selector = browserStringField(entry["selector"]),
                  !selector.isEmpty,
                  !seenSelectors.contains(selector) else {
                continue
            }
            seenSelectors.insert(selector)

            let roleRaw = browserStringField(entry["role"]) ?? "generic"
            let role = roleRaw.isEmpty ? "generic" : roleRaw
            let name = (browserStringField(entry["name"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let depth = max(0, browserIntField(entry["depth"]) ?? 0)

            let refToken = context.controlBrowserAutomationState.allocateElementRef(
                surfaceID: identity.surfaceID,
                selector: selector
            )
            let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

            var refInfo: [String: JSONValue] = ["role": .string(role)]
            if !name.isEmpty {
                refInfo["name"] = .string(name)
            }
            refs[shortRef] = .object(refInfo)

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

        var payload = browserIdentityFields(identity)
        payload["snapshot"] = .string(snapshotText)
        payload["title"] = .string(title)
        payload["url"] = .string(url)
        payload["ready_state"] = .string(readyState)
        payload["page"] = .object([
            "title": .string(title),
            "url": .string(url),
            "ready_state": .string(readyState),
            "text": .string(text),
            "html": .string(html),
        ])
        if !refs.isEmpty {
            payload["refs"] = .object(refs)
        }
        return .ok(.object(payload))
    }

    /// `as? String` twin for a JSON field.
    private func browserStringField(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        return raw
    }

    /// The legacy `as? Int` / `NSNumber.intValue` twin for a JSON field.
    private func browserIntField(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let raw):
            return Int(raw)
        case .double(let raw):
            return NSNumber(value: raw).intValue
        default:
            return nil
        }
    }

    /// The legacy `as? [[String: Any]] ?? []` twin: all elements must be
    /// objects or the whole array is treated as absent.
    private func browserObjectArrayField(_ value: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let raw)? = value else { return [] }
        var entries: [[String: JSONValue]] = []
        entries.reserveCapacity(raw.count)
        for element in raw {
            guard case .object(let entry) = element else { return [] }
            entries.append(entry)
        }
        return entries
    }

    /// The legacy `dict["ok"] as? Bool` twin (`Bool(exactly:)` semantics for
    /// numbers, as `NSNumber as? Bool` behaves).
    func browserOkFlag(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag):
            return flag
        case .int(let raw):
            return raw == 1 ? true : false
        case .double(let raw):
            return raw == 1.0 ? true : false
        default:
            return false
        }
    }

    // MARK: - cookies

    /// Serializes a cookie snapshot exactly as the legacy `v2BrowserCookieDict`.
    func browserCookieObject(_ cookie: ControlBrowserCookie) -> JSONValue {
        .object([
            "name": .string(cookie.name),
            "value": .string(cookie.value),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
            "secure": .bool(cookie.isSecure),
            "session_only": .bool(cookie.isSessionOnly),
            "expires": cookie.expiresEpoch.map { JSONValue.int($0) } ?? .null,
        ])
    }

    /// `browser.cookies.get` — read (and filter) the panel's cookies.
    func browserCookiesGet(_ params: [String: JSONValue]) -> ControlCallResult {
        switch context?.controlBrowserCookiesGet(target: browserSurfaceTarget(params))
            ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
        case .cookies(let identity, var cookies):
            if let name = string(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = string(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = string(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }
            var payload = browserIdentityFields(identity)
            payload["cookies"] = .array(cookies.map(browserCookieObject))
            return .ok(.object(payload))
        }
    }

    /// `browser.cookies.set` — write cookie rows (the `cookies` array, or the
    /// legacy single-cookie param shape).
    func browserCookiesSet(_ params: [String: JSONValue]) -> ControlCallResult {
        var rows: [JSONValue] = []
        if let arrayRows = browserCookieParamRows(params["cookies"]) {
            rows = arrayRows
        } else {
            var single: [String: JSONValue] = [:]
            if let name = string(params, "name") { single["name"] = .string(name) }
            if let value = string(params, "value") { single["value"] = .string(value) }
            if let url = string(params, "url") { single["url"] = .string(url) }
            if let domain = string(params, "domain") { single["domain"] = .string(domain) }
            if let path = string(params, "path") { single["path"] = .string(path) }
            if let secure = bool(params, "secure") { single["secure"] = .bool(secure) }
            if let expires = int(params, "expires") { single["expires"] = .int(Int64(expires)) }
            if !single.isEmpty {
                rows = [.object(single)]
            }
        }

        switch context?.controlBrowserCookiesSet(target: browserSurfaceTarget(params), rows: rows)
            ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .emptyPayload:
            return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
        case .invalidCookie(let row):
            return .err(
                code: "invalid_params",
                message: "Invalid cookie payload",
                data: .object(["cookie": row])
            )
        case .timedOutSetting(let name):
            return .err(
                code: "timeout",
                message: "Timed out setting cookie",
                data: .object(["name": .string(name)])
            )
        case .set(let identity, let count):
            var payload = browserIdentityFields(identity)
            payload["set"] = .int(Int64(count))
            return .ok(.object(payload))
        }
    }

    /// The legacy `params["cookies"] as? [[String: Any]]` twin: the array only
    /// counts when every element is an object (else the single-cookie shape
    /// applies).
    private func browserCookieParamRows(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let raw)? = value else { return nil }
        for element in raw {
            guard case .object = element else { return nil }
        }
        return raw
    }

    /// `browser.cookies.clear` — delete matching cookies.
    func browserCookiesClear(_ params: [String: JSONValue]) -> ControlCallResult {
        switch context?.controlBrowserCookiesClear(
            target: browserSurfaceTarget(params),
            name: string(params, "name"),
            domain: string(params, "domain"),
            hasAllParam: params["all"] != nil
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
        case .cleared(let identity, let removed):
            var payload = browserIdentityFields(identity)
            payload["cleared"] = .int(Int64(removed))
            return .ok(.object(payload))
        }
    }

    // MARK: - storage

    /// The legacy `v2BrowserStorageType` (`local` unless `session`).
    func browserStorageType(_ params: [String: JSONValue]) -> String {
        let type = (string(params, "storage") ?? string(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    /// `browser.storage.get` — read one key or the whole store.
    func browserStorageGet(_ params: [String: JSONValue]) -> ControlCallResult {
        let storageType = browserStorageType(params)
        let key = string(params, "key")
        let typeLiteral = browserJSONLiteral(.string(storageType))
        let keyLiteral = key.map { browserJSONLiteral(.string($0)) } ?? "null"
        let script = """
        (() => {
          const type = String(\(typeLiteral));
          const key = \(keyLiteral);
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          if (key == null) {
            const out = {};
            for (let i = 0; i < st.length; i++) {
              const k = st.key(i);
              out[k] = st.getItem(k);
            }
            return { ok: true, value: out };
          }
          return { ok: true, value: st.getItem(String(key)) };
        })()
        """
        switch context?.controlBrowserRunScript(
            target: browserSurfaceTarget(params),
            script: script,
            timeout: 5.0,
            mode: .frameAware(useEval: true)
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .resolved(let identity, let outcome):
            switch outcome {
            case .jsError(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .undefined:
                return .err(
                    code: "invalid_state",
                    message: "Storage unavailable",
                    data: .object(["type": .string(storageType)])
                )
            case .value(let value):
                guard case .object(let dict) = value, browserOkFlag(dict["ok"]) else {
                    return .err(
                        code: "invalid_state",
                        message: "Storage unavailable",
                        data: .object(["type": .string(storageType)])
                    )
                }
                var payload = browserIdentityFields(identity)
                payload["type"] = .string(storageType)
                payload["key"] = orNull(key)
                payload["value"] = dict["value"] ?? .null
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.storage.set` — write one key.
    func browserStorageSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let storageType = browserStorageType(params)
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        let typeLiteral = browserJSONLiteral(.string(storageType))
        let keyLiteral = browserJSONLiteral(.string(key))
        let valueLiteral = browserJSONLiteral(value)
        let script = """
        (() => {
          const type = String(\(typeLiteral));
          const key = String(\(keyLiteral));
          const value = \(valueLiteral);
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.setItem(key, value == null ? '' : String(value));
          return { ok: true };
        })()
        """
        switch context?.controlBrowserRunScript(
            target: browserSurfaceTarget(params),
            script: script,
            timeout: 5.0,
            mode: .frameAware(useEval: true)
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .resolved(let identity, let outcome):
            switch outcome {
            case .jsError(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .undefined:
                return .err(
                    code: "invalid_state",
                    message: "Storage unavailable",
                    data: .object(["type": .string(storageType)])
                )
            case .value(let value):
                guard case .object(let dict) = value, browserOkFlag(dict["ok"]) else {
                    return .err(
                        code: "invalid_state",
                        message: "Storage unavailable",
                        data: .object(["type": .string(storageType)])
                    )
                }
                var payload = browserIdentityFields(identity)
                payload["type"] = .string(storageType)
                payload["key"] = .string(key)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.storage.clear` — clear the store.
    func browserStorageClear(_ params: [String: JSONValue]) -> ControlCallResult {
        let storageType = browserStorageType(params)
        let typeLiteral = browserJSONLiteral(.string(storageType))
        let script = """
        (() => {
          const type = String(\(typeLiteral));
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.clear();
          return { ok: true };
        })()
        """
        switch context?.controlBrowserRunScript(
            target: browserSurfaceTarget(params),
            script: script,
            timeout: 5.0,
            mode: .frameAware(useEval: true)
        ) ?? .failure(.tabManagerUnavailable) {
        case .failure(let failure):
            return browserPanelFailureResult(failure)
        case .resolved(let identity, let outcome):
            switch outcome {
            case .jsError(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .undefined:
                return .err(
                    code: "invalid_state",
                    message: "Storage unavailable",
                    data: .object(["type": .string(storageType)])
                )
            case .value(let value):
                guard case .object(let dict) = value, browserOkFlag(dict["ok"]) else {
                    return .err(
                        code: "invalid_state",
                        message: "Storage unavailable",
                        data: .object(["type": .string(storageType)])
                    )
                }
                var payload = browserIdentityFields(identity)
                payload["type"] = .string(storageType)
                payload["cleared"] = .bool(true)
                return .ok(.object(payload))
            }
        }
    }
}
