package import CoreGraphics

/// The page-world script a swipe asks (`BrowserSwipeGesture`), and its answer. Owned by
/// `CEFSwipeNavigation`.
///
/// The script answers `[canScrollLeft, canScrollRight, consumesHorizontal]` for the viewport
/// point (CSS pixels) under the fingers:
/// - every horizontal scroller from the element there up to the root (`overflow-x` auto or
///   scroll with room to move; right-to-left scrollers count from their right edge), through
///   open shadow roots, and the document unless its `overflow-x` hides or clips it;
/// - a scroller, or the root element, with `overscroll-behavior-x` other than `auto` keeps the
///   gesture, as in Chrome (canvas apps and maps opt out of history swipes that way; `body`'s
///   value does not propagate, so an anti-bounce rule there keeps swipes);
/// - inside a same-origin frame under the point, the same walk in the frame's document. A frame
///   the page cannot read (another origin, or an embed or object) counts as scrolling both ways,
///   so it keeps the gesture: its own scrolling cannot be seen from outside;
/// - whether a horizontal `wheel` event in the last 600 ms ended `defaultPrevented` (a script
///   carousel), in the page or a same-origin frame it walked. The first probe installs that
///   listener: one capture listener per window, passive, that reads the event once its dispatch
///   finished. Its state lives under a registered symbol, not a named global. The answer waits
///   for the next frame (at most 50 ms) and that listener's read, so the wheels already sent to
///   the page are counted: Chromium hands wheels to the page on its next frame.
package nonisolated struct BrowserSwipeProbe: Sendable {
    /// How many frames deep the walk follows.
    package static let maxFrameDepth = 8

    package init() {}

    package func script(x: CGFloat, y: CGFloat) -> String {
        let px = Double(x).isFinite ? Double(x) : 0
        let py = Double(y).isFinite ? Double(y) : 0
        return """
        (async () => {
          const key = Symbol.for('cmux.swipe');
          let left = false, right = false, prevented = false;
          const watch = (win) => {
            let state = win[key];
            if (!state) {
              state = { prevented: -1e9 };
              Object.defineProperty(win, key, { value: state });
              win.addEventListener('wheel', (event) => {
                if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
                win.setTimeout(() => { if (event.defaultPrevented) state.prevented = win.performance.now(); }, 0);
              }, { capture: true, passive: true });
            }
            if (win.performance.now() - state.prevented < 600) prevented = true;
          };
          const room = (position, max) => { if (position > 1) left = true; if (position < max - 1) right = true; };
          const up = (el) => {
            if (el.parentElement) return el.parentElement;
            const node = el.getRootNode();
            return node && node.host ? node.host : null;
          };
          const scan = (win, x, y, depth) => {
            const doc = win.document;
            watch(win);
            let hit = doc.elementFromPoint(x, y);
            while (hit && hit.shadowRoot) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            for (let el = hit; el && el !== doc.documentElement && el !== doc.body; el = up(el)) {
              const style = win.getComputedStyle(el);
              if (style.overflowX !== 'auto' && style.overflowX !== 'scroll') continue;
              if (style.overscrollBehaviorX && style.overscrollBehaviorX !== 'auto') { left = true; right = true; }
              const max = el.scrollWidth - el.clientWidth;
              if (max <= 1) continue;
              room(style.direction === 'rtl' ? max + el.scrollLeft : el.scrollLeft, max);
            }
            const root = doc.scrollingElement || doc.documentElement;
            const hidden = (el) => el && ['hidden', 'clip'].includes(win.getComputedStyle(el).overflowX);
            const contained = (el) => el && (win.getComputedStyle(el).overscrollBehaviorX || 'auto') !== 'auto';
            if (contained(doc.documentElement)) { left = true; right = true; }
            if (root && !hidden(doc.documentElement) && !hidden(doc.body)) {
              const max = root.scrollWidth - root.clientWidth;
              const rtl = win.getComputedStyle(root).direction === 'rtl';
              if (max > 1) room(rtl ? max + win.scrollX : win.scrollX, max);
            }
            if (!hit) return;
            const tag = hit.tagName;
            if (tag === 'EMBED' || tag === 'OBJECT') { left = true; right = true; return; }
            if (tag !== 'IFRAME' && tag !== 'FRAME') return;
            let inner = null;
            try { inner = hit.contentWindow && hit.contentWindow.document ? hit.contentWindow : null; } catch (error) { inner = null; }
            if (!inner || depth >= \(Self.maxFrameDepth)) { left = true; right = true; return; }
            const rect = hit.getBoundingClientRect();
            scan(inner, x - rect.left - hit.clientLeft, y - rect.top - hit.clientTop, depth + 1);
          };
          watch(window);
          await new Promise((resolve) => {
            let done = false;
            const finish = () => { if (!done) { done = true; setTimeout(resolve, 0); } };
            requestAnimationFrame(finish);
            setTimeout(finish, 50);
          });
          scan(window, \(px), \(py), 0);
          return [left, right, prevented];
        })()
        """
    }

    /// The script's answer; nil for anything else (a page that broke the script).
    package func edges(_ value: BrowserJSValue) -> BrowserSwipeEdges? {
        guard case .array(let items) = value, items.count == 3,
              case .bool(let left) = items[0], case .bool(let right) = items[1], case .bool(let consumes) = items[2] else { return nil }
        return BrowserSwipeEdges(canScrollLeft: left, canScrollRight: right, consumesHorizontal: consumes)
    }
}
