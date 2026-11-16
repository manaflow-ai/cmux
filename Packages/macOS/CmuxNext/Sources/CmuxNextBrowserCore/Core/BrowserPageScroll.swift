/// A keyboard scroll of a browser page (Vimium's `j`, `k`, `gg`, `G`), as a script either engine
/// runs in an isolated world with no user gesture. It scrolls what the person sees scroll: the
/// document, or (an app page whose document does not scroll, such as a mail client) the
/// scrollable element around the focused one, else the largest one on screen.
public nonisolated enum BrowserPageScroll: Sendable, CaseIterable {
    /// One step down (`j`).
    case down
    /// One step up (`k`).
    case up
    /// The top (`gg`).
    case top
    /// The bottom (Shift-G).
    case bottom

    /// The catalog action that runs it (`browserScrollDown`, …).
    public var actionID: String {
        switch self {
        case .down: "browserScrollDown"
        case .up: "browserScrollUp"
        case .top: "browserScrollToTop"
        case .bottom: "browserScrollToBottom"
        }
    }

    /// Vimium's step, in CSS pixels.
    static let step = 60

    /// The script; it returns whether something scrolled. A step moves at once, so a held key
    /// keeps up; top and bottom glide unless the person asked for reduced motion.
    public var script: String {
        let move = switch self {
        case .down: "el.scrollBy({ top: \(Self.step), behavior: 'auto' })"
        case .up: "el.scrollBy({ top: -\(Self.step), behavior: 'auto' })"
        case .top: "el.scrollTo({ top: 0, behavior: glide })"
        case .bottom: "el.scrollTo({ top: el.scrollHeight, behavior: glide })"
        }
        return """
        (() => {
          const room = (el) => el && el.scrollHeight - el.clientHeight > 4;
          const scrolls = (el) => {
            if (!room(el)) return false;
            const y = getComputedStyle(el).overflowY;
            return y === 'auto' || y === 'scroll' || y === 'overlay';
          };
          let el = document.scrollingElement || document.documentElement;
          if (!room(el) || getComputedStyle(document.body || el).overflowY === 'hidden' && !scrolls(el)) {
            let near = document.activeElement;
            while (near && near !== document.body && !scrolls(near)) near = near.parentElement;
            if (near && near !== document.body && scrolls(near)) {
              el = near;
            } else {
              let best = null, area = 0, seen = 0;
              for (const each of document.body ? document.body.getElementsByTagName('*') : []) {
                if (++seen > 5000) break;
                if (!scrolls(each)) continue;
                const box = each.getBoundingClientRect();
                const shown = Math.max(0, Math.min(box.right, innerWidth) - Math.max(box.left, 0))
                  * Math.max(0, Math.min(box.bottom, innerHeight) - Math.max(box.top, 0));
                if (shown > area) { area = shown; best = each; }
              }
              if (best) el = best;
            }
          }
          const glide = matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
          const before = el.scrollTop;
          \(move);
          return el.scrollTop !== before || \(self == .top || self == .bottom ? "true" : "false");
        })()
        """
    }
}
