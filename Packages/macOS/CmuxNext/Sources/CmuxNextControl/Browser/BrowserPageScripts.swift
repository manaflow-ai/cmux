import Foundation

/// Page scripts for browser snapshot and element actions. Each returns a
/// JSON-compatible object; element actions return `{error}` when the
/// selector or ref matches nothing. `snapshot` tags elements with
/// `data-cmux-ref="eN"` so later actions can address `eN` / `@eN`.
enum BrowserPageScripts {
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Resolves `sel` (CSS selector, `eN`, or `@eN`) to an element as `el`:
    /// the document first, then inside open shadow roots and same-origin
    /// frames (browser use: an agent's selector reaches a web component or
    /// an embedded form as Playwright's does).
    static func find(_ selector: String) -> String {
        """
        const raw = \(literal(selector));
        const ref = raw.replace(/^@/, '');
        \(deepQuery)
        const el = /^e\\d+$/.test(ref) ? cmuxDeep(document, '[data-cmux-ref="' + ref + '"]', 0) : (document.querySelector(raw) || cmuxDeep(document, raw, 0));
        if (!el) { return { error: 'Element not found: ' + raw }; }
        \(measure)
        """
    }

    /// `cmuxDeep(root, sel, depth)`: the first match in `root`, then in open
    /// shadow roots and same-origin frames below it. A snapshot ref inside a
    /// web component or an embedded frame resolves the same way.
    static let deepQuery = """
        const cmuxDeep = (root, sel, depth) => { if (depth > 8) return null; let hit = null; try { hit = root.querySelector(sel); } catch (_) { return null; } if (hit) return hit; \
        for (const n of root.querySelectorAll('*')) { if (n.shadowRoot) { const h = cmuxDeep(n.shadowRoot, sel, depth + 1); if (h) return h; } \
        if (n.tagName === 'IFRAME' || n.tagName === 'FRAME') { let d = null; try { d = n.contentDocument; } catch (_) {} if (d) { const h = cmuxDeep(d, sel, depth + 1); if (h) return h; } } } return null; };
        """

    /// `cmuxAt(el)`: an element's rect in viewport CSS px and whether it
    /// hides its text, for the agent cursor (`BrowserPageAgentInput`).
    static let measure = """
        const cmuxAt = (e) => { try { const r0 = e.getBoundingClientRect(); let ox = 0, oy = 0; \
        try { let w = e.ownerDocument.defaultView; while (w && w !== window && w.frameElement) { const f = w.frameElement; const fr = f.getBoundingClientRect(); ox += fr.left + f.clientLeft; oy += fr.top + f.clientTop; w = w.parent; } } catch (_) {} \
        const r = { left: r0.left + ox, top: r0.top + oy, width: r0.width, height: r0.height }; const auto = String((e.getAttribute && e.getAttribute('autocomplete')) || '').toLowerCase(); \
        let css = 'none'; try { css = getComputedStyle(e).webkitTextSecurity || 'none'; } catch (_) {} \
        return { x: r.left, y: r.top, w: r.width, h: r.height, secret: String(e.type || '').toLowerCase() === 'password' || /password|one-time-code|cc-number|cc-csc/.test(auto) || css !== 'none' }; } catch (_) { return null; } };
        """

    static func wrap(_ body: String) -> String { "(() => {\n\(body)\n})()" }

    /// Evaluates `script` as an expression and returns a JSON-safe copy
    /// (`toJSON()` when present, else a structured clone through JSON). An
    /// exception it throws comes back as `{thrownKey: message}`, so only a
    /// wrapper that failed to parse throws.
    static func jsonSafe(_ script: String) -> String {
        "(() => { try { const v = (\n\(script)\n); if (v === undefined || v === null || typeof v !== 'object') return v; "
            + "if (typeof v.toJSON === 'function') return v.toJSON(); try { return JSON.parse(JSON.stringify(v)); } catch (e) { return String(v); } } "
            + "catch (e) { let m; try { m = String(e); } catch (_) { m = 'Uncaught exception'; } return { \(thrownKey): m }; } })()"
    }

    /// The key `jsonSafe` reports a thrown exception under.
    static let thrownKey = "__cmuxEvalError"

    static func click(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "el.scrollIntoView({block: 'center'}); const at = cmuxAt(el); el.click(); return { value: true, at };")
    }

    static func focus(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "el.focus(); return { value: true, at: cmuxAt(el) };")
    }

    static func fill(_ selector: String, _ text: String?) -> String {
        setValue(selector, text ?? "", append: false)
    }

    static func type(_ selector: String, _ text: String?) -> String {
        setValue(selector, text ?? "", append: true)
    }

    static func setValue(_ selector: String, _ text: String, append: Bool) -> String {
        wrap(find(selector) + """
        el.focus();
        const next = \(append ? "(el.isContentEditable ? (el.textContent || '') : (el.value || '')) + " : "")\(literal(text));
        const W = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        const proto = el instanceof W.HTMLTextAreaElement ? W.HTMLTextAreaElement.prototype : W.HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value');
        if (setter && setter.set && (el instanceof W.HTMLInputElement || el instanceof W.HTMLTextAreaElement)) { setter.set.call(el, next); }
        else if (el.isContentEditable) { el.textContent = next; } else { el.value = next; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { value: true, at: cmuxAt(el) };
        """)
    }

    static func text(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "return { value: el.innerText ?? el.textContent ?? '' };")
    }

    static func value(_ selector: String, _ text: String?) -> String {
        // A password field's value never leaves the page.
        wrap(find(selector) + "return { value: (el.type === 'password') ? null : (el.value ?? null) };")
    }
}
