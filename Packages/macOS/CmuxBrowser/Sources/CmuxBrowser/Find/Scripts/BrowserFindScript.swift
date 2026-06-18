import Foundation

/// A self-contained JavaScript snippet that drives find-in-page inside a `WKWebView`.
///
/// Each script is an immediately-invoked function expression evaluated against the page.
/// The search/next/previous variants scan visible text nodes with a `TreeWalker`, wrap matches
/// in `<mark>` elements, scroll the current match into view, and evaluate to a JSON string of
/// the shape `{"total":N,"current":M}`. The clear variant restores the DOM and removes the
/// injected highlight stylesheet. Parse the evaluation result with ``BrowserFindMatchCount/parse(_:)``.
public struct BrowserFindScript: Sendable, Equatable {
    /// The JavaScript source to evaluate in the page.
    public let source: String

    /// Wraps an already-formed JavaScript source string.
    /// - Parameter source: The JS source to evaluate.
    public init(source: String) {
        self.source = source
    }

    /// A script that highlights every occurrence of `query` in the document body.
    ///
    /// Highlights are case-insensitive. Previous highlights are removed first. The first match
    /// is marked current and scrolled to. Evaluates to `{"total":N,"current":0}`.
    /// - Parameter query: The needle to search for. An empty query clears highlights and reports zero matches.
    /// - Returns: The search script.
    public static func search(query: String) -> BrowserFindScript {
        let escaped = jsStringEscape(query)
        return BrowserFindScript(source: """
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
        """)
    }

    /// A script that advances to the next match, wrapping past the end. Evaluates to `{"total":N,"current":M}`.
    public static func next() -> BrowserFindScript {
        BrowserFindScript(source: """
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
        """)
    }

    /// A script that moves to the previous match, wrapping past the start. Evaluates to `{"total":N,"current":M}`.
    public static func previous() -> BrowserFindScript {
        BrowserFindScript(source: """
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
        """)
    }

    /// A script that removes all find highlights, drops the injected stylesheet, and restores the DOM.
    public static func clear() -> BrowserFindScript {
        BrowserFindScript(source: """
        (() => {
          \(clearBody)
          window.__cmuxFindMatches = [];
          window.__cmuxFindIndex = 0;
          const style = document.getElementById('__cmux-find-style');
          if (style) style.remove();
          return 'ok';
        })()
        """)
    }

    /// JS snippet (no wrapping IIFE) that removes existing mark highlights and re-normalizes parents.
    private static let clearBody = """
    document.querySelectorAll('mark.__cmux-find').forEach(mark => {
            const parent = mark.parentNode;
            if (!parent) return;
            const text = document.createTextNode(mark.textContent || '');
            parent.replaceChild(text, mark);
            parent.normalize();
          });
    """

    /// Escapes a Swift string for safe embedding inside a JS double-quoted string literal.
    ///
    /// Backslashes, double quotes, and the control characters that would otherwise break out of
    /// a JS string literal (including the line/paragraph separators `U+2028`/`U+2029`) are escaped.
    /// The result does not include the surrounding quotes; the caller splices it between its own.
    private static func jsStringEscape(_ string: String) -> String {
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
