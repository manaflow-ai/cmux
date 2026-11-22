public import Foundation

/// The page side of link hints, run in the tab's isolated world (never the
/// page's world or an agent's): it lists clickable elements in the viewport
/// and draws the labels in an open shadow root on a `cmux-link-hints`
/// element, so page styles cannot restyle them. The host keeps the targets
/// and clicks by position, so no element reference crosses calls. A scroll
/// or resize removes the labels (their positions would be stale).
public nonisolated extension LinkHintSession {
    internal static let overlayTag = "cmux-link-hints"

    /// Returns a JSON string: `[{x, y, left, top, href}]`, at most 1000,
    /// in document order. Hidden, disabled and covered elements are skipped.
    static let collectScript = """
    (() => {
      const selector = 'a[href],area[href],button,input:not([type=hidden]),select,textarea,summary,label[for],' +
        '[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],' +
        '[onclick],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"])';
      const width = innerWidth, height = innerHeight, out = [];
      for (const element of document.querySelectorAll(selector)) {
        if (element.disabled || element.closest('[inert],[aria-hidden=true]')) continue;
        const rect = Array.from(element.getClientRects()).find((r) =>
          r.width > 2 && r.height > 2 && r.bottom > 0 && r.right > 0 && r.top < height && r.left < width);
        if (!rect) continue;
        const style = getComputedStyle(element);
        if (style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
        const left = Math.max(rect.left, 0), top = Math.max(rect.top, 0);
        const x = (left + Math.min(rect.right, width)) / 2, y = (top + Math.min(rect.bottom, height)) / 2;
        const hit = document.elementFromPoint(x, y);
        if (!hit || !(hit === element || element.contains(hit) || hit.contains(element))) continue;
        const href = typeof element.href === 'string' ? element.href : null;
        out.push({ x: Math.round(x), y: Math.round(y), left: Math.round(left), top: Math.round(top), href });
        if (out.length >= 1000) break;
      }
      return JSON.stringify(out);
    })()
    """

    /// Draws `labels` (uppercase, monospace) at each target's top-left
    /// corner, replacing any earlier labels.
    static func drawScript(_ hints: [(label: String, target: LinkHintTarget)]) -> String {
        let items = hints.map { ["label": $0.label, "left": $0.target.left, "top": $0.target.top] as [String: Any] }
        let json = (try? JSONSerialization.data(withJSONObject: items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        ((hints) => {
          document.querySelector('\(overlayTag)')?.remove();
          const host = document.createElement('\(overlayTag)');
          host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
          const root = host.attachShadow({ mode: 'open' });
          const style = document.createElement('style');
          style.textContent = `span{position:absolute;font:700 11px/14px ui-monospace,Menlo,monospace;` +
            `letter-spacing:.04em;padding:0 3px;color:#16130a;background:#ffd84d;border:1px solid #8a6d00;` +
            `border-radius:2px;box-shadow:0 1px 3px rgba(0,0,0,.35);white-space:pre}` +
            `span[hidden]{display:none}b{color:#9a7b00;font-weight:700}`;
          root.append(style);
          for (const hint of hints) {
            const label = document.createElement('span');
            label.dataset.label = hint.label;
            label.textContent = hint.label.toUpperCase();
            label.style.left = hint.left + 'px';
            label.style.top = hint.top + 'px';
            root.append(label);
          }
          document.documentElement.append(host);
          const drop = () => host.remove();
          addEventListener('scroll', drop, { once: true, capture: true });
          addEventListener('resize', drop, { once: true });
          return true;
        })(\(json))
        """
    }

    /// Shows only labels that start with `prefix`, the typed part dimmed.
    /// Returns false when the labels are gone (scrolled away).
    static func narrowScript(_ prefix: String) -> String {
        """
        ((prefix) => {
          const host = document.querySelector('\(overlayTag)');
          if (!host || !host.shadowRoot) return false;
          for (const label of host.shadowRoot.querySelectorAll('span')) {
            const text = label.dataset.label;
            label.hidden = !text.startsWith(prefix);
            const typed = document.createElement('b');
            typed.textContent = prefix.toUpperCase();
            label.replaceChildren(...(prefix && !label.hidden ? [typed] : []), text.slice(label.hidden ? 0 : prefix.length).toUpperCase());
          }
          return true;
        })(\(scriptLiteral(prefix)))
        """
    }

    /// Removes the labels. Returns false when they were already gone.
    static let removeScript = """
    (() => {
      const host = document.querySelector('\(overlayTag)');
      if (!host) return false;
      host.remove();
      return true;
    })()
    """

    /// `text` as a JavaScript string literal.
    internal static func scriptLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    /// The targets the collect script returned; empty when it returned
    /// anything else.
    static func targets(from value: BrowserJSValue) -> [LinkHintTarget] {
        guard case .string(let json) = value,
              let targets = try? JSONDecoder().decode([LinkHintTarget].self, from: Data(json.utf8)) else { return [] }
        return targets
    }
}
