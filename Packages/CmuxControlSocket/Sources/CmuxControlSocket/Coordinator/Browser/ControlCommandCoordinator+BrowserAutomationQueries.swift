internal import Foundation

/// The browser DOM read-only query bodies (`browser.get.*` / `browser.is.*`),
/// with their injected JS byte-identical to the legacy `v2BrowserGet*` /
/// `v2BrowserIs*` originals.
extension ControlCommandCoordinator {
    /// `browser.get.text` — an element's inner text.
    func browserGetText(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    /// `browser.get.html` — an element's outer HTML.
    func browserGetHTML(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    /// `browser.get.value` — an element's value (or text content).
    func browserGetValue(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    /// `browser.get.attr` — an element attribute.
    func browserGetAttr(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let attr = string(params, "attr") ?? string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return browserSelectorAction(params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = browserJSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    /// `browser.get.title` — the page title.
    func browserGetTitle(_ params: [String: JSONValue]) -> ControlCallResult {
        withBrowserPanel(params) { workspaceID, surfaceID in
            var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            payload["title"] = .string(browserContext?.controlBrowserPageTitle(surfaceID: surfaceID) ?? "")
            return .ok(.object(payload))
        }
    }

    /// `browser.get.count` — the number of elements matching a selector.
    func browserGetCount(_ params: [String: JSONValue]) -> ControlCallResult {
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
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var count = 0
                if case .value(let jsonValue) = value {
                    count = browserNumberInt(jsonValue) ?? 0
                }
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["count"] = .int(Int64(count))
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.get.box` — an element's bounding rect.
    func browserGetBox(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    /// `browser.get.styles` — one computed style property, or the standard
    /// visibility/layout subset.
    func browserGetStyles(_ params: [String: JSONValue]) -> ControlCallResult {
        let property = string(params, "property")
        return browserSelectorAction(params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = browserJSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    /// `browser.is.visible` — whether an element is rendered and visible.
    func browserIsVisible(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    /// `browser.is.enabled` — whether an element is enabled.
    func browserIsEnabled(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    /// `browser.is.checked` — whether a checkbox/radio is checked.
    func browserIsChecked(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }
}
