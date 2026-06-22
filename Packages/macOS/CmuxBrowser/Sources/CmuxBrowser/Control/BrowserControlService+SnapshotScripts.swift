import Foundation

/// JavaScript builder for the `browser.snapshot` accessibility-tree DOM walk.
///
/// This is the pure, app-agnostic string-composition half of the former
/// `TerminalController.v2BrowserSnapshot` body: the in-page script that walks the
/// DOM, classifies roles, computes accessible names and CSS paths, and returns the
/// `title`/`url`/`ready_state`/`text`/`html`/`entries` payload. It takes only the
/// already-decoded snapshot options (the `interactive`/`cursor`/`compact` flags as
/// literal `"true"`/`"false"` tokens, the clamped `maxDepth`, and the
/// already-`jsonLiteral`-escaped scope-selector token, `"null"` when absent), so it
/// carries no `WebKit`, main-actor, or per-surface state.
///
/// The WebKit evaluation, the per-surface element-ref allocation, the
/// Swift-side tree-line rendering, and the wire-payload shaping stay in the app
/// target on the nonisolated socket-worker lane, exactly where they ran before:
/// only the byte-identical script assembly moved here.
extension BrowserControlService {
    /// The `browser.snapshot` in-page DOM-walk script.
    ///
    /// Byte-identical to the script the former `v2BrowserSnapshot` body assembled
    /// inline; the caller runs it through `v2RunBrowserJavaScript` with
    /// `useEval: false` and decodes the returned `entries` array into the wire
    /// payload.
    ///
    /// - Parameters:
    ///   - interactiveLiteral: `"true"`/`"false"` for the interactive-only filter.
    ///   - cursorLiteral: `"true"`/`"false"` for the click-affordance sweep.
    ///   - compactLiteral: `"true"`/`"false"` for the structural-role name gate.
    ///   - maxDepth: the clamped maximum DOM-walk depth.
    ///   - scopeLiteral: the already-`jsonLiteral`-escaped scope selector, or the
    ///     bare `"null"` token when no scope selector was provided.
    /// - Returns: a self-invoking JavaScript expression resolving to the snapshot
    ///   object.
    public func snapshotScript(
        interactiveLiteral: String,
        cursorLiteral: String,
        compactLiteral: String,
        maxDepth: Int,
        scopeLiteral: String
    ) -> String {
        return """
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
    }
}
