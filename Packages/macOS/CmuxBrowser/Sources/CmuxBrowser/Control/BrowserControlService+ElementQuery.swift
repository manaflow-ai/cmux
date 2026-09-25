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
          let start = 0;
          let quote = null;
          let escaped = false;
          let brackets = 0;
          let parentheses = 0;
          for (let index = 0; index < source.length; index += 1) {
            const character = source[index];
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
              parts.push(source.slice(start, index).trim());
              index += 2;
              start = index + 1;
            }
          }
          parts.push(source.slice(start).trim());
          return parts.filter(Boolean);
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
            const matches = [];
            const seen = new Set();
            for (const root of roots) {
              __cmuxCollectMatches(root, parts[index], matches, seen);
            }
            if (index === parts.length - 1) return matches;
            // A generated snapshot path uses `>>>` between every ancestor,
            // including ordinary light-DOM hops. Keep the matched element as
            // a search root for those hops, and add its open shadow root when
            // the next segment crosses into a web component.
            roots = matches.flatMap((element) => {
              const nextRoots = [element];
              if (element.shadowRoot) nextRoots.push(element.shadowRoot);
              return nextRoots;
            });
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
