import Foundation

/// JavaScript snippets for find-in-page in WKWebView.
///
/// Uses TreeWalker to scan text nodes and wraps matches with `<mark>` elements.
/// The current match gets an additional `.current` class and is scrolled into view.
enum BrowserFindJavaScript {

    // MARK: - Public API

    /// Returns JS that highlights all occurrences of `query` in the document body.
    /// Supports matches that span across multiple DOM elements (e.g. plain text into `<code>` blocks).
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

          // Phase 1: Collect all visible text nodes and build a concatenated text map.
          const walker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_TEXT,
            { acceptNode(node) { return isVisible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } }
          );
          const textNodes = [];
          const nodeOffsets = [];  // cumulative offset for each text node in the concatenated string
          let concatenated = '';
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const text = node.textContent || '';
            nodeOffsets.push(concatenated.length);
            textNodes.push(node);
            concatenated += text;
          }

          // Phase 2: Find all matches in the concatenated (cross-element) text.
          const lowerConcat = concatenated.toLowerCase();
          const matchPositions = [];
          let searchFrom = 0;
          while (true) {
            const idx = lowerConcat.indexOf(lowerQuery, searchFrom);
            if (idx === -1) break;
            matchPositions.push({ start: idx, end: idx + query.length });
            searchFrom = idx + 1;  // Allow overlapping matches
          }
          if (matchPositions.length === 0) return JSON.stringify({ total: 0, current: 0 });

          // Phase 3: Resolve each match back to text node ranges and wrap with <mark>.
          // A single match may span multiple text nodes; we track the first <mark> per match for navigation.
          const matchGroups = [];  // Array of arrays of <mark> elements, one group per match

          // Find which text node contains a given offset.
          const findNodeIndex = (offset) => {
            let lo = 0, hi = textNodes.length - 1;
            while (lo < hi) {
              const mid = (lo + hi + 1) >> 1;
              if (nodeOffsets[mid] <= offset) lo = mid; else hi = mid - 1;
            }
            return lo;
          };

          // We must process matches in reverse document order to avoid invalidating
          // earlier node references when we split text nodes.
          for (let mi = matchPositions.length - 1; mi >= 0; mi--) {
            const match = matchPositions[mi];
            const startNodeIdx = findNodeIndex(match.start);
            const endNodeIdx = findNodeIndex(match.end - 1);
            const marks = [];

            if (startNodeIdx === endNodeIdx) {
              // Match is entirely within one text node.
              const node = textNodes[startNodeIdx];
              const localStart = match.start - nodeOffsets[startNodeIdx];
              const localEnd = match.end - nodeOffsets[startNodeIdx];
              const text = node.textContent || '';
              const parent = node.parentNode;
              if (!parent) continue;

              const frag = document.createDocumentFragment();
              if (localStart > 0) frag.appendChild(document.createTextNode(text.substring(0, localStart)));
              const mark = document.createElement('mark');
              mark.className = MARK_CLASS;
              mark.textContent = text.substring(localStart, localEnd);
              frag.appendChild(mark);
              marks.push(mark);
              if (localEnd < text.length) frag.appendChild(document.createTextNode(text.substring(localEnd)));
              parent.replaceChild(frag, node);
            } else {
              // Match spans multiple text nodes. Wrap the relevant portion of each.
              // Process in reverse to preserve node references.
              for (let ni = endNodeIdx; ni >= startNodeIdx; ni--) {
                const node = textNodes[ni];
                const text = node.textContent || '';
                const nodeStart = nodeOffsets[ni];
                const parent = node.parentNode;
                if (!parent) continue;

                let localStart = 0;
                let localEnd = text.length;
                if (ni === startNodeIdx) localStart = match.start - nodeStart;
                if (ni === endNodeIdx) localEnd = match.end - nodeStart;

                const frag = document.createDocumentFragment();
                if (localStart > 0) frag.appendChild(document.createTextNode(text.substring(0, localStart)));
                const mark = document.createElement('mark');
                mark.className = MARK_CLASS;
                mark.textContent = text.substring(localStart, localEnd);
                frag.appendChild(mark);
                marks.unshift(mark);  // prepend so marks are in document order
                if (localEnd < text.length) frag.appendChild(document.createTextNode(text.substring(localEnd)));
                parent.replaceChild(frag, node);
              }
            }
            matchGroups.unshift(marks);  // prepend so groups are in document order
          }

          // For navigation, use the first <mark> in each match group.
          const navigationMarks = matchGroups.map(g => g[0]);
          window.__cmuxFindMatches = navigationMarks;
          window.__cmuxFindMatchGroups = matchGroups;
          window.__cmuxFindIndex = 0;

          if (navigationMarks.length > 0) {
            matchGroups[0].forEach(m => m.classList.add(CURRENT_CLASS));
            navigationMarks[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
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

          return JSON.stringify({ total: navigationMarks.length, current: 0 });
        })()
        """
    }

    /// Returns JS that moves to the next match. Evaluates to `{"total":N,"current":M}`.
    static func nextScript() -> String {
        """
        (() => {
          const matches = window.__cmuxFindMatches || [];
          const groups = window.__cmuxFindMatchGroups || matches.map(m => [m]);
          if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
          let idx = window.__cmuxFindIndex || 0;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindMatchGroups = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          (groups[idx] || [matches[idx]]).forEach(m => m.classList.remove('__cmux-find-current'));
          idx = (idx + 1) % matches.length;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindMatchGroups = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          (groups[idx] || [matches[idx]]).forEach(m => m.classList.add('__cmux-find-current'));
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
          const groups = window.__cmuxFindMatchGroups || matches.map(m => [m]);
          if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
          let idx = window.__cmuxFindIndex || 0;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindMatchGroups = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          (groups[idx] || [matches[idx]]).forEach(m => m.classList.remove('__cmux-find-current'));
          idx = (idx - 1 + matches.length) % matches.length;
          if (!matches[idx] || !matches[idx].isConnected) {
            window.__cmuxFindMatches = [];
            window.__cmuxFindMatchGroups = [];
            window.__cmuxFindIndex = 0;
            return JSON.stringify({ total: 0, current: 0 });
          }
          (groups[idx] || [matches[idx]]).forEach(m => m.classList.add('__cmux-find-current'));
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
          window.__cmuxFindMatchGroups = [];
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
