import Foundation

/// Page scripts for browser snapshot and element actions. Each returns a
/// JSON-compatible object; element actions return `{error}` when the
/// selector or ref matches nothing. `snapshot` tags elements with
/// `data-cmux-ref="eN"` so later actions can address `eN` / `@eN`.
enum CompatBrowserScripts {
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Resolves `sel` (CSS selector, `eN`, or `@eN`) to an element as `el`.
    static func find(_ selector: String) -> String {
        """
        const raw = \(literal(selector));
        const ref = raw.replace(/^@/, '');
        const el = /^e\\d+$/.test(ref) ? document.querySelector('[data-cmux-ref="' + ref + '"]') : document.querySelector(raw);
        if (!el) { return { error: 'Element not found: ' + raw }; }
        """
    }

    static func wrap(_ body: String) -> String { "(() => {\n\(body)\n})()" }

    /// Evaluates `script` as an expression and returns a JSON-safe copy
    /// (`toJSON()` when present, else a structured clone through JSON).
    static func jsonSafe(_ script: String) -> String {
        "(() => { const v = (\n\(script)\n); if (v === undefined || v === null || typeof v !== 'object') return v; "
            + "if (typeof v.toJSON === 'function') return v.toJSON(); try { return JSON.parse(JSON.stringify(v)); } catch (e) { return String(v); } })()"
    }

    static func click(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "el.scrollIntoView({block: 'center'}); el.click(); return { value: true };")
    }

    static func focus(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "el.focus(); return { value: true };")
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
        const next = \(append ? "(el.value || '') + " : "")\(literal(text));
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value');
        if (setter && setter.set && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) { setter.set.call(el, next); }
        else if (el.isContentEditable) { el.textContent = next; } else { el.value = next; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { value: true };
        """)
    }

    static func text(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "return { value: el.innerText ?? el.textContent ?? '' };")
    }

    static func value(_ selector: String, _ text: String?) -> String {
        wrap(find(selector) + "return { value: el.value ?? null };")
    }

    static func snapshot(selector: String?, maxDepth: Int, interactiveOnly: Bool) -> String {
        wrap("""
        const root = \(selector.map { "document.querySelector(\(literal($0)))" } ?? "document.body");
        if (!root) { return { error: 'Element not found' }; }
        const interactive = new Set(['A','BUTTON','INPUT','SELECT','TEXTAREA','SUMMARY','OPTION']);
        const roleOf = (el) => el.getAttribute('role') || ({A:'link',BUTTON:'button',INPUT:(el.type==='checkbox'?'checkbox':el.type==='radio'?'radio':'textbox'),SELECT:'combobox',TEXTAREA:'textbox',IMG:'img',H1:'heading',H2:'heading',H3:'heading',H4:'heading',H5:'heading',H6:'heading',UL:'list',OL:'list',LI:'listitem',NAV:'navigation',MAIN:'main',FORM:'form',TABLE:'table',P:'paragraph',LABEL:'label'}[el.tagName]);
        const nameOf = (el) => (el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('placeholder') || el.getAttribute('title') || (el.tagName==='INPUT' ? (el.value||'') : (el.innerText||'')).trim().replace(/\\s+/g,' ')).slice(0, 80);
        let next = 1; const refs = {}; const lines = [];
        const visit = (el, depth) => {
          if (depth > \(max(1, maxDepth)) || !(el instanceof Element)) return;
          const style = getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') return;
          const role = roleOf(el);
          const isInteractive = interactive.has(el.tagName) || el.hasAttribute('onclick') || el.getAttribute('tabindex') === '0';
          let shown = false;
          if (role && (!\(interactiveOnly) || isInteractive)) {
            const ref = 'e' + (next++);
            el.setAttribute('data-cmux-ref', ref);
            const name = nameOf(el);
            refs[ref] = { role, name };
            lines.push('  '.repeat(depth) + '- ' + role + (name ? ' "' + name.replace(/"/g, "'") + '"' : '') + ' [ref=' + ref + ']');
            shown = true;
          }
          if (role === 'link' || role === 'button' || role === 'textbox' || role === 'heading') return;
          for (const child of el.children) visit(child, shown ? depth + 1 : depth);
        };
        visit(root, 0);
        return { snapshot: lines.join('\\n'), refs, title: document.title, url: location.href,
                 ready_state: document.readyState, text: (document.body ? document.body.innerText : '').slice(0, 20000) };
        """)
    }
}
