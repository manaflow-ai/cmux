import Foundation

extension BrowserControlService {
    /// JavaScript helpers shared by browser selectors, waits, and interaction
    /// commands. A plain CSS selector keeps its normal meaning, while `>>>`
    /// explicitly crosses an open shadow root. Plain selectors also search
    /// descendants of open roots so refs returned by a snapshot remain useful
    /// when a component does not expose a host path.
    public var elementQueryPrelude: String {
        """
        const __cmuxSelectorParts = (selector) => {
          const source = String(selector || '');
          const parts = [];
          let crossesShadowRoot = false;
          let start = 0;
          let quote = null;
          let escaped = false;
          let comment = false;
          let escapedOutsideQuote = false;
          let brackets = 0;
          let parentheses = 0;
          for (let index = 0; index < source.length; index += 1) {
            const character = source[index];
            if (comment) {
              if (character === '*' && source[index + 1] === '/') {
                comment = false;
                index += 1;
              }
              continue;
            }
            if (escapedOutsideQuote) {
              escapedOutsideQuote = false;
              continue;
            }
            if (quote) {
              if (escaped) {
                escaped = false;
              } else if (character === '\\\\') {
                escaped = true;
              } else if (character === quote) {
                quote = null;
              }
              continue;
            }
            if (character === '/' && source[index + 1] === '*') {
              comment = true;
              index += 1;
              continue;
            }
            if (character === '\\\\') {
              escapedOutsideQuote = true;
              continue;
            }
            if (character === '\"' || character === "'") {
              quote = character;
              continue;
            }
            if (character === '[') {
              brackets += 1;
              continue;
            }
            if (character === ']') {
              brackets = Math.max(0, brackets - 1);
              continue;
            }
            if (character === '(') {
              parentheses += 1;
              continue;
            }
            if (character === ')') {
              parentheses = Math.max(0, parentheses - 1);
              continue;
            }
            if (brackets === 0 && parentheses === 0
                && character === '>' && source[index + 1] === '>'
                && source[index + 2] === '>') {
              const part = source.slice(start, index).trim();
              if (part) parts.push({ selector: part, crossesShadowRoot });
              index += 2;
              start = index + 1;
              crossesShadowRoot = true;
            }
          }
          const part = source.slice(start).trim();
          if (part) parts.push({ selector: part, crossesShadowRoot });
          return parts;
        };
        const __cmuxCollectMatches = (root, selector, output, seen) => {
          if (!root || typeof root.querySelectorAll !== 'function') return;
          const matches = Array.from(root.querySelectorAll(selector));
          for (const element of matches) {
            if (!seen.has(element)) {
              seen.add(element);
              output.push(element);
            }
          }
          const hosts = Array.from(root.querySelectorAll('*'));
          for (const host of hosts) {
            if (host.shadowRoot) __cmuxCollectMatches(host.shadowRoot, selector, output, seen);
          }
        };
        const __cmuxQueryAll = (selector) => {
          const parts = __cmuxSelectorParts(selector);
          if (!parts.length) return [];
          let roots = [document];
          for (let index = 0; index < parts.length; index += 1) {
            const part = parts[index];
            const matches = [];
            const seen = new Set();
            if (index === 0 || !part.crossesShadowRoot) {
              for (const root of roots) {
                __cmuxCollectMatches(root, part.selector, matches, seen);
              }
            } else {
              for (const root of roots) {
                __cmuxCollectMatches(root.shadowRoot, part.selector, matches, seen);
              }
            }
            if (index === parts.length - 1) return matches;
            roots = matches;
          }
          return [];
        };
        const __cmuxQuery = (selector) => __cmuxQueryAll(selector)[0] || null;
        const __cmuxCssPath = (el) => {
          if (!el || el.nodeType !== 1) return null;
          const parts = [];
          const separators = [];
          let cur = el;
          while (cur && cur.nodeType === 1) {
            let part = String(cur.tagName || '').toLowerCase();
            if (!part) break;
            if (cur.id) {
              part = '#' + CSS.escape(cur.id);
            } else {
              const root = cur.parentElement || cur.getRootNode();
              const siblings = root && root.children
                ? Array.from(root.children).filter((n) => String(n.tagName || '').toLowerCase() === part)
                : [];
              if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(cur) + 1})`;
            }
            const root = cur.getRootNode && cur.getRootNode();
            const crossesShadowRoot = !cur.parentElement && !!(root && root.host);
            // A shadow-root child has no element ancestor in its CSS tree.
            // Anchor it so a matching nested subtree cannot win the query.
            if (crossesShadowRoot) part += ':not(* *)';
            parts.unshift(part);
            const parent = crossesShadowRoot ? root.host : cur.parentElement;
            if (parent) separators.unshift(crossesShadowRoot ? ' >>> ' : ' > ');
            cur = parent;
          }
          return parts.reduce((path, part, index) => {
            return index === 0 ? part : path + separators[index - 1] + part;
          }, '');
        };
        const __cmuxDeepActiveElement = () => {
          let active = document.activeElement;
          while (active && active.shadowRoot && active.shadowRoot.activeElement) {
            active = active.shadowRoot.activeElement;
          }
          return active;
        };
        """
    }

    /// Injects the shared selector helpers into a generated self-invoking
    /// browser script. Keeping this at the service boundary ensures every
    /// selector action gets the same shadow-root traversal semantics.
    public func scriptWithElementQueryHelpers(_ script: String) -> String {
        guard let marker = script.range(of: "(() => {") else { return script }
        let insertion = marker.upperBound
        return String(script[..<insertion])
            + "\n"
            + elementQueryPrelude
            + "\n"
            + String(script[insertion...])
    }
}
