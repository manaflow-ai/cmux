import Foundation

/// JavaScript builders for the browser-control element locators and diagnostics.
///
/// Every string returned here is byte-identical to the script the corresponding
/// `v2Browser*` method previously assembled inline; only the assembly moved.
extension BrowserControlService {
    /// JavaScript probe that reports how a CSS `selector` resolves on the page:
    /// match count, visible-match count, a small descriptor sample, a snapshot
    /// excerpt, and page title/url/body context. Used to build the rich
    /// element-not-found diagnostics payload.
    /// - Parameter selector: the selector to probe.
    /// - Returns: a self-invoking JavaScript expression.
    public func notFoundDiagnosticsScript(selector: String) -> String {
        let selectorLiteral = jsonLiteral(selector)
        return """
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
    }

    /// Wraps a `find.*` finder body in the shared CSS-path harness that returns
    /// `{ ok, selector, tag, text }` for the matched element. The finder body must
    /// evaluate to an `Element` or `null`.
    /// - Parameter finderBody: the locator-specific JavaScript that selects an element.
    /// - Returns: a self-invoking JavaScript expression.
    public func findScript(finderBody: String) -> String {
        return """
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
    }

    /// Finder body for `find.role`: matches by explicit or implicit ARIA role,
    /// optionally filtered by accessible name.
    /// - Parameters:
    ///   - role: the lowercased target role.
    ///   - name: the optional lowercased accessible name.
    ///   - exact: whether the name must match exactly.
    /// - Returns: a JavaScript finder body for ``findScript(finderBody:)``.
    public func findRoleFinderBody(role: String, name: String?, exact: Bool) -> String {
        let roleLiteral = jsonLiteral(role)
        let nameLiteral = name.map(jsonLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"
        return """
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
    }

    /// Finder body for `find.text`: matches the first element whose normalized
    /// text contains (or equals, when `exact`) the target.
    public func findTextFinderBody(text: String, exact: Bool) -> String {
        let textLiteral = jsonLiteral(text)
        let exactLiteral = exact ? "true" : "false"
        return """
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
    }

    /// Finder body for `find.label`: resolves the form control associated with a
    /// matching `<label>` via its `for` attribute or nested control.
    public func findLabelFinderBody(label: String, exact: Bool) -> String {
        let labelLiteral = jsonLiteral(label)
        let exactLiteral = exact ? "true" : "false"
        return """
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
    }

    /// Finder body for `find.placeholder`: matches by `placeholder` attribute.
    public func findPlaceholderFinderBody(placeholder: String, exact: Bool) -> String {
        let placeholderLiteral = jsonLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"
        return """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """
    }

    /// Finder body for `find.alt`: matches by `alt` attribute.
    public func findAltFinderBody(alt: String, exact: Bool) -> String {
        let altLiteral = jsonLiteral(alt)
        let exactLiteral = exact ? "true" : "false"
        return """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """
    }

    /// Finder body for `find.title`: matches by `title` attribute.
    public func findTitleFinderBody(title: String, exact: Bool) -> String {
        let titleLiteral = jsonLiteral(title)
        let exactLiteral = exact ? "true" : "false"
        return """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """
    }

    /// Finder body for `find.testid`: matches `data-testid`/`data-test-id`/`data-test`.
    public func findTestIdFinderBody(testId: String) -> String {
        let testIdLiteral = jsonLiteral(testId)
        return """
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
    }

    /// Script for `find.first`: resolves the first match of `selector` and echoes
    /// its trimmed text.
    public func findFirstScript(selector: String) -> String {
        let selectorLiteral = jsonLiteral(selector)
        return """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
        })()
        """
    }

    /// Script for `find.last`: resolves the last match of `selector`, returning a
    /// `:nth-of-type` selector for it.
    public func findLastScript(selector: String) -> String {
        let selectorLiteral = jsonLiteral(selector)
        return """
        (() => {
          const list = document.querySelectorAll(\(selectorLiteral));
          if (!list || list.length === 0) return { ok: false, error: 'not_found' };
          const idx = list.length - 1;
          const el = list[idx];
          const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
          return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
        })()
        """
    }

    /// Script for `find.nth`: resolves the `index`-th match of `selector`
    /// (negative indices count from the end), returning a `:nth-of-type` selector.
    public func findNthScript(selector: String, index: Int) -> String {
        let selectorLiteral = jsonLiteral(selector)
        return """
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
    }
}
