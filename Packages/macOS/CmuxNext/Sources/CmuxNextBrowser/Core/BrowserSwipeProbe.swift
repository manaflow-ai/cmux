import CoreGraphics

/// The page-world script a swipe asks (`BrowserSwipeGesture`), and its answer.
///
/// The script answers `[canScrollLeft, canScrollRight, consumesHorizontal]` for the viewport
/// point (CSS pixels) under the fingers:
/// - every horizontal scroller from the element there up to the root (`overflow-x` auto or
///   scroll with room to move; right-to-left scrollers count from their right edge), and the
///   document unless its `overflow-x` hides or clips it;
/// - whether a horizontal `wheel` event in the last 600 ms ended `defaultPrevented` (a script
///   carousel). The first probe installs that listener: one capture listener on `window`,
///   passive, that reads the event once its dispatch finished. Its state lives under a
///   registered symbol, not a named global.
nonisolated enum BrowserSwipeProbe {
    static func script(x: CGFloat, y: CGFloat) -> String {
        let px = Double(x).isFinite ? Double(x) : 0
        let py = Double(y).isFinite ? Double(y) : 0
        return """
        (() => {
          const key = Symbol.for('cmux.swipe');
          let state = window[key];
          if (!state) {
            state = { prevented: -1e9 };
            Object.defineProperty(window, key, { value: state });
            window.addEventListener('wheel', (event) => {
              if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
              setTimeout(() => { if (event.defaultPrevented) state.prevented = performance.now(); }, 0);
            }, { capture: true, passive: true });
          }
          let left = false, right = false;
          const room = (position, max) => { if (position > 1) left = true; if (position < max - 1) right = true; };
          for (let el = document.elementFromPoint(\(px), \(py)); el && el !== document.documentElement && el !== document.body; el = el.parentElement) {
            const style = getComputedStyle(el);
            if (style.overflowX !== 'auto' && style.overflowX !== 'scroll') continue;
            const max = el.scrollWidth - el.clientWidth;
            if (max <= 1) continue;
            room(style.direction === 'rtl' ? max + el.scrollLeft : el.scrollLeft, max);
          }
          const root = document.scrollingElement || document.documentElement;
          const hidden = (el) => el && ['hidden', 'clip'].includes(getComputedStyle(el).overflowX);
          if (root && !hidden(document.documentElement) && !hidden(document.body)) {
            const max = root.scrollWidth - root.clientWidth;
            const rtl = getComputedStyle(root).direction === 'rtl';
            if (max > 1) room(rtl ? max + window.scrollX : window.scrollX, max);
          }
          return [left, right, performance.now() - state.prevented < 600];
        })()
        """
    }

    /// The script's answer; nil for anything else (a page that broke the script).
    static func edges(_ value: BrowserJSValue) -> BrowserSwipeEdges? {
        guard case .array(let items) = value, items.count == 3,
              case .bool(let left) = items[0], case .bool(let right) = items[1], case .bool(let consumes) = items[2] else { return nil }
        return BrowserSwipeEdges(canScrollLeft: left, canScrollRight: right, consumesHorizontal: consumes)
    }
}
