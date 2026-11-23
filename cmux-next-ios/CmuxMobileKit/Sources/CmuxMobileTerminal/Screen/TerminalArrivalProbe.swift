#if os(iOS) && DEBUG
import CmuxMobileSupport
import QuartzCore
import UIKit

/// DEBUG only. What the keyboard pin trace's arrival fields
/// (`-cmux-mobile-arrival-trace`, TerminalArrivalBenchUITests) read of the
/// terminal page on screen, every display frame: its views (the page, the
/// surface, the bottom stack, the key row, the composer and its field), the
/// page's safe area, the scroll offset, and how many frames Ghostty presented
/// on this page so far (the first one is the terminal's first paint).
///
/// Leo, 2026-11-23: "there's like various little like odd little like shifts
/// when I like arrive at the terminal. Like it doesn't settle well."
///
/// Read-only: it never changes a view, a layout or a responder.
@MainActor
public enum TerminalArrivalProbe {
    public struct Snapshot {
        /// `pg` (the page), `sv`, `ss`, `kr`, `cp`, `fd`: nil when hidden.
        public var parts: [(name: String, view: UIView?)]
        public var page: UIView
        public var presents: Int
        public var scrollOffset: CGFloat
        public var safeArea: UIEdgeInsets
        /// Distinguishes two pages (a new page is a new number).
        public var pageNumber: Int
    }

    private final class Entry {
        weak var controller: TerminalViewController?
        var presents = 0
        let number: Int
        init(_ controller: TerminalViewController, number: Int) {
            self.controller = controller
            self.number = number
        }
    }

    private static var entries: [Entry] = []
    private static var made = 0

    static func register(_ controller: TerminalViewController) {
        entries.removeAll { $0.controller == nil }
        guard !entries.contains(where: { $0.controller === controller }) else { return }
        made += 1
        entries.append(Entry(controller, number: made))
    }

    static func presented(_ controller: TerminalViewController) {
        entries.first { $0.controller === controller }?.presents += 1
    }

    /// The terminal page that shows the most of itself in `window`, if any.
    public static func snapshot(in window: UIWindow) -> Snapshot? {
        let probe = MobileKeyboardProbe()
        var best: (entry: Entry, controller: TerminalViewController, area: CGFloat)?
        for entry in entries {
            guard let controller = entry.controller, controller.isViewLoaded, controller.view.window === window,
                  !controller.view.isHidden else { continue }
            let visible = probe.onScreen(controller.view, in: window).intersection(window.bounds)
            let area = visible.isNull ? 0 : visible.width * visible.height
            if area > (best?.area ?? 0) { best = (entry, controller, area) }
        }
        guard let best else { return nil }
        let controller = best.controller
        func shown(_ view: UIView?) -> UIView? {
            guard let view, !view.isHidden, view.alpha > 0.01, view.window === window else { return nil }
            return view
        }
        var parts: [(name: String, view: UIView?)] = [("pg", controller.view)]
        for part in controller.arrivalParts() { parts.append((name: part.name, view: shown(part.view))) }
        return Snapshot(parts: parts, page: controller.view, presents: best.entry.presents,
                        scrollOffset: controller.arrivalScrollOffset, safeArea: controller.view.safeAreaInsets,
                        pageNumber: best.entry.number)
    }
}
#endif
