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
                // New paths use >>> only at an open shadow boundary. Keep a
                // light-DOM fallback for refs emitted by older cmux versions
                // that used >>> for every ancestor hop.
                const shadowRoot = root.shadowRoot;
                __cmuxCollectMatches(shadowRoot || root, part.selector, matches, seen);
              }
            }
            if (index === parts.length - 1) return matches;
            roots = matches;
          }
          return [];
        };
        const __cmuxQuery = (selector) => __cmuxQueryAll(selector)[0] || null;
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
