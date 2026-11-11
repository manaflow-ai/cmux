public import Foundation

/// The page side of link hints, run in the tab's isolated world (never the
/// page's world or an agent's): it lists clickable elements in the viewport
/// and draws the labels in an open shadow root on a `cmux-link-hints`
/// element, so page styles cannot restyle them. The host keeps the targets
/// and clicks by position, so no element reference crosses calls. A scroll
/// or resize removes the labels (their positions would be stale).
public nonisolated extension LinkHintSession {
    internal static let overlayTag = "cmux-link-hints"

    /// Returns a JSON string: `[{x, y, left, top, href, text}]` (CSS
    /// pixels in the viewport; `text` names the element), at most 1000, in
    /// document order. Hidden, disabled and covered elements are skipped.
    /// Window hint mode runs it in first-party pages too.
    public static let collectScript = """
    (() => {
      const selector = 'a[href],area[href],button,input:not([type=hidden]),select,textarea,summary,label[for],' +
        '[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=option],' +
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
        const named = (element.getAttribute('aria-labelledby') || '').split(/\\s+/)
          .map((id) => document.getElementById(id)?.innerText || '').join(' ').trim();
        const text = (element.getAttribute('aria-label') || named || element.labels?.[0]?.innerText || element.title ||
          element.innerText || element.value || '').toString().trim().slice(0, 80);
        out.push({ x: Math.round(x), y: Math.round(y), left: Math.round(left), top: Math.round(top), href, text });
        if (out.length >= 1000) break;
      }
      return JSON.stringify(out);
    })()
    """

    /// The page's own answer to whether a text field has the keyboard, read from the focused element only:
    /// `{"editing": Bool}`. The browser's editable-focus flag can be stale after an address-bar load (#32573): then a
    /// letter typed into a field started link hints. A link-hint session asks this first and collects its targets only
    /// when no field has the keyboard (lead on STATUS 7898: a heavy page's target walk never delays a field's keys).
    /// A focused same-origin frame is looked into; a focused cross-origin frame (an embedded video, a payment form)
    /// counts as editing, as its focus cannot be read: hints start again once it loses focus.
    public static let focusScript = "(() => {\n" + editingCheck + "  return JSON.stringify({ editing });\n})()"

    /// The statements that set `editing` (``focusScript``).
    private static let editingCheck = """
      let doc = document, active = document.activeElement, frame = false;
      for (;;) {
        while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
        if (active?.tagName !== 'IFRAME' && active?.tagName !== 'FRAME') break;
        let inner = null;
        try { inner = active.contentDocument; } catch (e) {}
        if (!inner) { frame = true; break; }
        doc = inner;
        active = inner.activeElement;
      }
      const tag = active?.tagName || '';
      const editing = frame || doc.designMode === 'on' || !!active?.isContentEditable || tag === 'TEXTAREA' || tag === 'SELECT' ||
        (tag === 'INPUT' && !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit'].includes(active.type));
    """

    /// Draws `labels` (uppercase, monospace) at each target's top-left
    /// corner, replacing any earlier labels.
    package static func drawScript(_ hints: [(label: String, target: LinkHintTarget)]) -> String {
        let items = hints.map { ["label": $0.label, "left": $0.target.left, "top": $0.target.top] as [String: Any] }
        let json = (try? JSONSerialization.data(withJSONObject: items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        ((hints) => {
          document.querySelector('\(overlayTag)')?.remove();
          const host = document.createElement('\(overlayTag)');
          host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
          const root = host.attachShadow({ mode: 'open' });
          const style = document.createElement('style');
          // Legible on any page, light or dark: one warm yellow with a hairline ring and a soft lift,
          // crisp text, digits of one width, and a 90ms rise (none under reduced motion).
          style.textContent = `span{position:absolute;box-sizing:border-box;min-width:16px;height:16px;` +
            `font:650 11px/16px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.06em;text-align:center;` +
            `font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased;padding:0 4px;color:#1f1700;` +
            `background:#ffd84d;border-radius:4px;white-space:pre;user-select:none;` +
            `box-shadow:0 0 0 1px rgba(110,84,0,.55),0 1px 2px rgba(0,0,0,.25),0 2px 6px rgba(0,0,0,.18);` +
            `transform-origin:top left;animation:cmux-hint-in 90ms cubic-bezier(.2,.8,.2,1)}` +
            `@keyframes cmux-hint-in{from{opacity:0;transform:scale(.96)}}` +
            `@media (prefers-reduced-motion:reduce){span{animation:none}}` +
            `@media (prefers-color-scheme:dark){span{box-shadow:0 0 0 1px rgba(0,0,0,.6),0 2px 8px rgba(0,0,0,.5)}}` +
            `span[hidden]{display:none}b{color:rgba(31,23,0,.42);font-weight:650}`;
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
    package static func narrowScript(_ prefix: String) -> String {
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

    /// Clicks the element at `target`'s center (an engine with no trusted host click, WebKit):
    /// a field or other focusable element takes the keyboard, then gets the click.
    package static func clickScript(_ target: LinkHintTarget) -> String {
        """
        (() => {
          const hit = document.elementFromPoint(\(target.x), \(target.y));
          if (!hit) return false;
          const element = hit.closest('a[href],area[href],button,input,select,textarea,summary,label,[role],[onclick],[tabindex],[contenteditable]') || hit;
          if (typeof element.focus === 'function') element.focus({ preventScroll: true });
          if (typeof element.click === 'function') element.click();
          return true;
        })()
        """
    }

    /// Removes the labels. Returns false when they were already gone.
    package static let removeScript = """
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

    /// ``focusScript``'s answer (whether a text field has the keyboard), or targets.
    private struct Answer: Decodable {
        var editing: Bool?
        var targets: [LinkHintTarget]?
    }

    /// The answer of ``focusScript``, or of ``collectScript`` (targets only: not editing).
    private static func answer(from value: BrowserJSValue) -> Answer? {
        guard case .string(let json) = value else { return nil }
        let data = Data(json.utf8)
        return (try? JSONDecoder().decode(Answer.self, from: data)) ?? (try? JSONDecoder().decode([LinkHintTarget].self, from: data)).map { Answer(editing: nil, targets: $0) }
    }

    /// Whether the page said a text field has the keyboard.
    package static func editing(from value: BrowserJSValue) -> Bool { answer(from: value)?.editing == true }

    /// The targets the collect script returned; empty when it returned
    /// anything else.
    package static func targets(from value: BrowserJSValue) -> [LinkHintTarget] { answer(from: value)?.targets ?? [] }
}
