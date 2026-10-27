import Foundation

/// The page script for `browser.page.snapshot`: a Playwright-like outline
/// (`- role "name" [state] [ref=eN] [cursor=pointer] [offscreen]: value`).
extension BrowserPageScripts {
    /// Walks `selector` (the body without one) through open shadow roots and
    /// same-origin frames, tags each listed element `data-cmux-ref="eN"`
    /// (`find` resolves a ref wherever it is), and names it as assistive
    /// technology would: `aria-labelledby`, `aria-label`, a field's labels,
    /// a button input's value, then content including image `alt`, SVG
    /// `<title>` and a child's `aria-label`/`title`. `cursor: pointer`
    /// elements (not inheriting it), `onclick` and `tabindex=0` count as
    /// clickables. A select lists its first 20 options. Names and values
    /// stop at 80 characters, and a secret field's value never leaves the page.
    static func snapshot(selector: String?, maxDepth: Int, interactiveOnly: Bool) -> String {
        let root = selector.map { "(document.querySelector(\(literal($0))) || cmuxDeep(document, \(literal($0)), 0))" } ?? "document.body"
        return wrap(deepQuery + #"""
        const root = \#(root);
        if (!root) { return { error: 'Element not found' }; }
        const maxDepth = \#(max(1, maxDepth)), interactiveOnly = \#(interactiveOnly);
        // Refs address the latest snapshot only, in every root they reach.
        const eachRoot = (r, fn, depth) => { if (depth > 8) return; fn(r); for (const n of r.querySelectorAll('*')) { if (n.shadowRoot) eachRoot(n.shadowRoot, fn, depth + 1);
          if (n.tagName === 'IFRAME' || n.tagName === 'FRAME') { let d = null; try { d = n.contentDocument; } catch (_) {} if (d) eachRoot(d, fn, depth + 1); } } };
        eachRoot(document, (r) => r.querySelectorAll('[data-cmux-ref]').forEach((old) => old.removeAttribute('data-cmux-ref')), 0);
        const skipTags = new Set(['SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT', 'HEAD', 'META', 'LINK']);
        const interactiveTags = new Set(['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY', 'OPTION']);
        const interactiveRoles = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'textbox', 'searchbox', 'combobox', 'listbox', 'option',
          'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'slider', 'spinbutton', 'treeitem', 'generic']);
        const contentNamed = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'option', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab',
          'treeitem', 'heading', 'paragraph', 'listitem', 'label', 'cell', 'gridcell', 'columnheader', 'rowheader', 'generic', 'tooltip']);
        const leafRoles = new Set(['link', 'button', 'textbox', 'searchbox', 'combobox', 'listbox', 'checkbox', 'radio', 'switch', 'option', 'slider', 'spinbutton']);
        const checkable = new Set(['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio']);
        const tagRoles = new Map(Object.entries({ A: 'link', BUTTON: 'button', TEXTAREA: 'textbox', IMG: 'img', H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
          UL: 'list', OL: 'list', LI: 'listitem', NAV: 'navigation', MAIN: 'main', FORM: 'form', TABLE: 'table', P: 'paragraph', LABEL: 'label', SUMMARY: 'button', OPTION: 'option', DIALOG: 'dialog' }));
        const clip = (s) => String(s || '').slice(0, 80);
        const squash = (s) => String(s || '').replace(/\s+/g, ' ').trim();
        const styleOf = (n) => { try { return ((n.ownerDocument && n.ownerDocument.defaultView) || window).getComputedStyle(n); } catch (_) { return null; } };
        const hidden = (s) => !!s && (s.display === 'none' || s.visibility === 'hidden');
        const typeOf = (el) => String(el.getAttribute('type') || 'text').toLowerCase();
        const parentOf = (n) => { if (n.parentElement) return n.parentElement; const r = n.getRootNode ? n.getRootNode() : null; if (r && r.host) return r.host;
          try { return (n.ownerDocument && n.ownerDocument.defaultView && n.ownerDocument.defaultView.frameElement) || null; } catch (_) { return null; } };
        const secret = (el) => { if (typeOf(el) === 'password' || (el.hasAttribute && el.hasAttribute('\#(secretMark)'))) return true; if (/password|one-time-code|cc-number|cc-csc/.test(String(el.getAttribute('autocomplete') || '').toLowerCase())) return true;
          const s = styleOf(el); return !!s && (s.webkitTextSecurity || 'none') !== 'none'; };
        const kidsOf = (n) => { if (n.tagName === 'SLOT') { const a = n.assignedNodes({ flatten: true }); return a.length ? a : n.childNodes; } return n.shadowRoot ? n.shadowRoot.childNodes : n.childNodes; };
        // Text as a name: alt, SVG titles, children's labels; controls inside (a wrapping label's field) are left out.
        const textOf = (node) => {
          const out = []; let len = 0, seen = 0;
          const add = (s) => { s = squash(s); if (s) { out.push(' ' + s + ' '); len += s.length; } };
          const walk = (n, d) => {
            if (len > 200 || seen++ > 2000 || d > 30) return;
            if (n.nodeType === 3) { out.push(n.nodeValue); len += n.nodeValue.length; return; }
            if (n.nodeType === 11) { for (const c of n.childNodes) walk(c, d + 1); return; }
            if (n.nodeType !== 1 || skipTags.has(n.tagName)) return;
            const t = n.tagName;
            if (d > 0) {
              if (n.getAttribute('aria-hidden') === 'true' || hidden(styleOf(n))) return;
              const own = squash(n.getAttribute('aria-label')); if (own) { add(own); return; }
              if (t === 'INPUT' || t === 'SELECT' || t === 'TEXTAREA') return;
            }
            if (t === 'IMG' || t === 'AREA') { add(n.getAttribute('alt') || n.getAttribute('title')); return; }
            if (n.localName === 'svg') { const title = Array.from(n.children).find((c) => c.localName === 'title'); add(title ? title.textContent : n.getAttribute('title')); return; }
            if (t === 'BR') { out.push(' '); return; }
            const before = len;
            out.push(' ');
            for (const c of kidsOf(n)) walk(c, d + 1);
            out.push(' ');
            if (len === before && d > 0) add(n.getAttribute('title'));
          };
          walk(node, 0);
          return squash(out.join(''));
        };
        const byIds = (el, attr) => { const ids = squash(el.getAttribute(attr)); if (!ids) return ''; const r = el.getRootNode ? el.getRootNode() : el.ownerDocument;
          return squash(ids.split(' ').map((id) => { const n = (r && r.getElementById ? r.getElementById(id) : null) || el.ownerDocument.getElementById(id); return n ? (squash(n.getAttribute('aria-label')) || textOf(n)) : ''; }).join(' ')); };
        const roleOf = (el) => {
          const attr = squash(el.getAttribute('role')).split(' ')[0];
          if (attr && attr !== 'none' && attr !== 'presentation') return attr;
          const t = el.tagName;
          if (t === 'INPUT') { const ty = typeOf(el); if (ty === 'hidden') return null; if (ty === 'checkbox' || ty === 'radio') return ty;
            if (ty === 'button' || ty === 'submit' || ty === 'reset' || ty === 'image') return 'button'; if (ty === 'range') return 'slider'; return 'textbox'; }
          if (t === 'SELECT') return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
          if (el.isContentEditable) { const p = parentOf(el); if (!(p && p.isContentEditable)) return 'textbox'; }
          return tagRoles.get(t) || null;
        };
        const nameOf = (el, role) => {
          const t = el.tagName, ty = typeOf(el);
          let n = byIds(el, 'aria-labelledby') || squash(el.getAttribute('aria-label'));
          if (n) return n;
          if (t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT') {
            if (t === 'INPUT' && (ty === 'submit' || ty === 'reset' || ty === 'button')) { n = squash(el.value) || (ty === 'submit' ? 'Submit' : ty === 'reset' ? 'Reset' : ''); if (n) return n; }
            if (t === 'INPUT' && ty === 'image') { n = squash(el.getAttribute('alt')); if (n) return n; }
            n = squash(Array.from(el.labels || []).map(textOf).join(' '));
            return n || squash(el.getAttribute('placeholder') || el.getAttribute('title'));
          }
          if (t === 'IMG') { n = squash(el.getAttribute('alt')); if (n) return n; }
          if (contentNamed.has(role)) { n = textOf(el); if (n) return n; }
          return squash(el.getAttribute('title') || el.getAttribute('placeholder'));
        };
        const valueOf = (el, role) => {
          const t = el.tagName;
          if (t === 'SELECT') return squash(Array.from(el.selectedOptions || []).map((o) => o.label || o.textContent).join(', '));
          if (!(role === 'textbox' || role === 'searchbox' || role === 'combobox' || role === 'spinbutton' || role === 'slider')) return '';
          if (t === 'INPUT' || t === 'TEXTAREA') return secret(el) ? '' : squash(el.value);
          if (el.isContentEditable) return squash(el.textContent);
          return '';
        };
        const stateOf = (el, role, info) => {
          const marks = [], t = el.tagName;
          if (checkable.has(role)) {
            let c = false;
            if (t === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) c = el.indeterminate ? 'mixed' : !!el.checked;
            else { const a = el.getAttribute('aria-checked'); c = a === 'mixed' ? 'mixed' : a === 'true'; }
            info.checked = c; marks.push(c === true ? 'checked' : 'checked=' + c);
          }
          let disabled = el.getAttribute('aria-disabled') === 'true';
          try { disabled = disabled || el.matches(':disabled'); } catch (_) {}
          if (disabled) { info.disabled = true; marks.push('disabled'); }
          let expanded = el.getAttribute('aria-expanded');
          if (expanded === null && t === 'SUMMARY' && el.parentElement && el.parentElement.tagName === 'DETAILS') expanded = String(el.parentElement.open);
          if (expanded === 'true' || expanded === 'false') { info.expanded = expanded === 'true'; marks.push(info.expanded ? 'expanded' : 'expanded=false'); }
          if (el.getAttribute('aria-pressed') === 'true') { info.pressed = true; marks.push('pressed'); }
          if ((t === 'OPTION' && el.selected) || el.getAttribute('aria-selected') === 'true') { info.selected = true; marks.push('selected'); }
          return marks;
        };
        const offscreen = (el) => { try { const r = el.getBoundingClientRect(); if (!r.width && !r.height) return false; let ox = 0, oy = 0, w = el.ownerDocument.defaultView;
          while (w && w !== window && w.frameElement) { const f = w.frameElement.getBoundingClientRect(); ox += f.left; oy += f.top; w = w.parent; }
          const left = r.left + ox, top = r.top + oy; return top + r.height <= 0 || top >= window.innerHeight || left + r.width <= 0 || left >= window.innerWidth; } catch (_) { return false; } };
        let next = 1; const refs = {}; const lines = [];
        const emit = (el, role, depth, pointer) => {
          const ref = 'e' + (next++);
          el.setAttribute('data-cmux-ref', ref);
          const name = clip(nameOf(el, role));
          const info = { role, name };
          const marks = stateOf(el, role, info);
          const value = clip(valueOf(el, role));
          if (value) info.value = value;
          Object.assign(refs, { [ref]: info });
          lines.push('  '.repeat(depth) + '- ' + role + (name ? ' "' + name.replace(/"/g, "'") + '"' : '') + marks.map((m) => ' [' + m + ']').join('') + ' [ref=' + ref + ']'
            + (pointer ? ' [cursor=pointer]' : '') + (offscreen(el) ? ' [offscreen]' : '') + (value ? ': ' + value : ''));
        };
        const options = (el, depth) => {
          const all = Array.from(el.options || []);
          for (const o of all.slice(0, 20)) {
            const ref = 'e' + (next++);
            o.setAttribute('data-cmux-ref', ref);
            const name = clip(squash(o.label || o.textContent));
            const info = { role: 'option', name, value: o.value };
            const marks = [];
            if (o.selected) { info.selected = true; marks.push('selected'); }
            if (o.disabled) { info.disabled = true; marks.push('disabled'); }
            Object.assign(refs, { [ref]: info });
            lines.push('  '.repeat(depth) + '- option' + (name ? ' "' + name.replace(/"/g, "'") + '"' : '') + marks.map((m) => ' [' + m + ']').join('') + ' [ref=' + ref + ']'
              + (o.value !== name ? ': ' + clip(o.value) : ''));
          }
          if (all.length > 20) lines.push('  '.repeat(depth) + '- ... ' + (all.length - 20) + ' more options');
        };
        const visit = (el, depth, level) => {
          if (depth > maxDepth || level > 400 || !el || el.nodeType !== 1 || skipTags.has(el.tagName)) return;
          const t = el.tagName;
          const style = styleOf(el);
          if (hidden(style)) return;
          let role = roleOf(el);
          const parent = parentOf(el), parentStyle = parent ? styleOf(parent) : null;
          const pointer = !!style && style.cursor === 'pointer' && !(parentStyle && parentStyle.cursor === 'pointer') && t !== 'BODY' && t !== 'HTML';
          const clickable = pointer || el.hasAttribute('onclick') || el.getAttribute('tabindex') === '0';
          if (!role && clickable && t !== 'BODY' && t !== 'HTML') role = 'generic';
          const isInteractive = interactiveTags.has(t) || interactiveRoles.has(role) || clickable;
          let shown = false;
          if (role && (!interactiveOnly || isInteractive)) { emit(el, role, depth, pointer); shown = true; }
          if (t === 'SELECT') { if (shown) options(el, depth + 1); return; }
          if (leafRoles.has(role)) return;
          const below = shown ? depth + 1 : depth;
          if (t === 'IFRAME' || t === 'FRAME') { let d = null; try { d = el.contentDocument; } catch (_) {} if (d && d.body) visit(d.body, below, level + 1); return; }
          const kids = t === 'SLOT' ? (el.assignedElements({ flatten: true }).length ? el.assignedElements({ flatten: true }) : el.children) : (el.shadowRoot ? el.shadowRoot.children : el.children);
          for (const child of kids) visit(child, below, level + 1);
        };
        visit(root, 0, 0);
        return { snapshot: lines.join('\n'), refs, title: document.title, url: location.href,
                 ready_state: document.readyState, text: (document.body ? document.body.innerText : '').slice(0, 20000) };
        """#)
    }
}
