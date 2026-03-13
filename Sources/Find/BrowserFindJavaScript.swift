import Foundation

/// JavaScript snippets for find-in-page in WKWebView.
///
/// Uses TreeWalker to scan text nodes and wraps matches with `<mark>` elements.
/// The current match gets an additional `.current` class and is scrolled into view.
enum BrowserFindJavaScript {

    // MARK: - Public API

    /// Returns JS that highlights all occurrences of `query` in the document body.
    /// The script evaluates to a JSON string `{"total":N,"current":0}`.
    static func searchScript(query: String) -> String {
        let escaped = jsStringEscape(query)
        return """
        (() => {
          const MARK_CLASS = '__cmux-find';
          const CURRENT_CLASS = '__cmux-find-current';

          // Remove previous highlights first.
          \(clearBody)

          const query = "\(escaped)";
          if (!query) return JSON.stringify({total: 0, current: 0});

          const lowerQuery = query.toLowerCase();
          const SKIP_TAGS = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','IFRAME','SVG']);
          const isVisible = (el) => {
            while (el && el !== document.body) {
              if (SKIP_TAGS.has(el.tagName)) return false;
              if (el.getAttribute('aria-hidden') === 'true') return false;
              const st = getComputedStyle(el);
              if (st.display === 'none' || st.visibility === 'hidden') return false;
              el = el.parentElement;
            }
            return true;
          };
          const walker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_TEXT,
            { acceptNode(node) { return isVisible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } }
          );
          const matches = [];
          const textNodes = [];
          while (walker.nextNode()) textNodes.push(walker.currentNode);

          for (const node of textNodes) {
            const text = node.textContent || '';
            const lowerText = text.toLowerCase();
            let startIndex = 0;
            const parts = [];
            let lastEnd = 0;
            while (true) {
              const idx = lowerText.indexOf(lowerQuery, startIndex);
              if (idx === -1) break;
              parts.push({ start: idx, end: idx + query.length });
              startIndex = idx + query.length;
            }
            if (parts.length === 0) continue;

            const parent = node.parentNode;
            if (!parent) continue;
            const frag = document.createDocumentFragment();
            let pos = 0;
            for (const part of parts) {
              if (part.start > pos) {
                frag.appendChild(document.createTextNode(text.substring(pos, part.start)));
              }
              const mark = document.createElement('mark');
              mark.className = MARK_CLASS;
              mark.textContent = text.substring(part.start, part.end);
              frag.appendChild(mark);
              matches.push(mark);
              pos = part.end;
            }
            if (pos < text.length) {
              frag.appendChild(document.createTextNode(text.substring(pos)));
            }
            parent.replaceChild(frag, node);
          }

          window.__cmuxFindMatches = matches;
          window.__cmuxFindIndex = 0;

          if (matches.length > 0) {
            matches[0].classList.add(CURRENT_CLASS);
            matches[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
          }

          // Inject highlight styles if not already present.
          if (!document.getElementById('__cmux-find-style')) {
            const style = document.createElement('style');
            style.id = '__cmux-find-style';
            style.textContent = `
              mark.__cmux-find { background: #facc15; color: #000; border-radius: 2px; }
              mark.__cmux-find.__cmux-find-current { background: #f97316; color: #fff; }
            `;
            document.head.appendChild(style);
          }

          return JSON.stringify({ total: matches.length, current: 0 });
        })()
        """
    }

    /// Returns JS that moves to the next match. Evaluates to `{"total":N,"current":M}`.
    static func nextScript() -> String {
        """
        (() => {
          const matches = window.__cmuxFindMatches || [];
          if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
          let idx = window.__cmuxFindIndex || 0;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          matches[idx].classList.remove('__cmux-find-current');
          idx = (idx + 1) % matches.length;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          matches[idx].classList.add('__cmux-find-current');
          matches[idx].scrollIntoView({ block: 'center', behavior: 'smooth' });
          window.__cmuxFindIndex = idx;
          return JSON.stringify({ total: matches.length, current: idx });
        })()
        """
    }

    /// Returns JS that moves to the previous match. Evaluates to `{"total":N,"current":M}`.
    static func previousScript() -> String {
        """
        (() => {
          const matches = window.__cmuxFindMatches || [];
          if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
          let idx = window.__cmuxFindIndex || 0;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          matches[idx].classList.remove('__cmux-find-current');
          idx = (idx - 1 + matches.length) % matches.length;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          matches[idx].classList.add('__cmux-find-current');
          matches[idx].scrollIntoView({ block: 'center', behavior: 'smooth' });
          window.__cmuxFindIndex = idx;
          return JSON.stringify({ total: matches.length, current: idx });
        })()
        """
    }

    /// Returns JS that removes all find highlights and restores the DOM.
    static func clearScript() -> String {
        """
        (() => {
          \(clearBody)
          window.__cmuxFindMatches = [];
          window.__cmuxFindIndex = 0;
          const style = document.getElementById('__cmux-find-style');
          if (style) style.remove();
          return 'ok';
        })()
        """
    }

    // MARK: - Internal

    /// JS snippet (no wrapping IIFE) that removes existing mark highlights.
    private static let clearBody = """
    document.querySelectorAll('mark.__cmux-find').forEach(mark => {
            const parent = mark.parentNode;
            if (!parent) return;
            const text = document.createTextNode(mark.textContent || '');
            parent.replaceChild(text, mark);
            parent.normalize();
          });
    """

    /// Escape a Swift string for safe embedding inside a JS double-quoted string literal.
    static func jsStringEscape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\0"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                result.append(Character(scalar))
            }
        }
        return result
    }
}
