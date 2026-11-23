#if DEBUG && os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import QuartzCore
import UIKit

/// `-cmux-mobile-arrival-trace` (with `-cmux-mobile-kbd-pin-trace`): the
/// keyboard pin trace's per-frame line also carries the terminal page as
/// drawn (presentation layers, window points), for the terminal arrival
/// bench (TerminalArrivalBenchUITests, scripts/measure/ios_terminal_arrival.py).
///
/// Leo, 2026-11-23: "there's like various little like odd little like shifts
/// when I like arrive at the terminal. Like it doesn't settle well."
///
/// Fields: `ar=1` a terminal page is on screen (`ar=0` none), `pn=` which page
/// (a new page, a new number), `pr=` frames Ghostty presented on it so far
/// (the first is its first paint), `so=` its scroll offset, `sa=top,bottom`
/// its safe area, then `NAME=x,y,w,h` (or `-`, not shown) for `pg` the page,
/// `sv` the terminal surface, `ss` the bottom stack, `kr` the key row, `cp`
/// the composer, `fd` its field, `nb` the navigation bar, `nt`/`nl`/`nr` the
/// bar's leaf views nearest its middle (the title), its left and its right
/// end, and `tb` the tab bar.
@MainActor
final class TerminalArrivalFields {
    static let flag = "-cmux-mobile-arrival-trace"
    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    private weak var bar: UINavigationBar?
    private weak var tabBar: UITabBar?
    private var frames = 0

    func fields(in window: UIWindow) -> String {
        let probe = MobileKeyboardProbe()
        func rect(_ view: UIView?) -> String {
            guard let view else { return "-" }
            let r = probe.onScreen(view, in: window)
            return String(format: "%.1f,%.1f,%.1f,%.1f", r.minX, r.minY, r.width, r.height)
        }
        var out: [String] = []
        if let page = TerminalArrivalProbe.snapshot(in: window) {
            out.append("ar=1 pn=\(page.pageNumber) pr=\(page.presents)")
            out.append(String(format: "so=%.1f sa=%.1f,%.1f", page.scrollOffset, page.safeArea.top, page.safeArea.bottom))
            for part in page.parts { out.append("\(part.name)=\(rect(part.view))") }
        } else {
            out.append("ar=0")
        }
        // The bars: found again every 30 frames (or when gone), read every frame.
        frames += 1
        if frames % 30 == 1 || !Self.drawn(bar, in: window) {
            bar = Self.find(in: window, where: { view in view is UINavigationBar && Self.drawn(view, in: window) }) as? UINavigationBar
        }
        if frames % 30 == 1 || !Self.drawn(tabBar, in: window) {
            tabBar = Self.find(in: window, where: { view in view is UITabBar && Self.drawn(view, in: window) }) as? UITabBar
        }
        if let bar, Self.drawn(bar, in: window) {
            out.append("nb=\(rect(bar))")
            let leaves = Self.leaves(of: bar, in: window, width: bar.bounds.width)
            let mid = probe.onScreen(bar, in: window).midX
            let title = leaves.min { abs($0.rect.midX - mid) < abs($1.rect.midX - mid) }
            let left = leaves.min { $0.rect.minX < $1.rect.minX }
            let right = leaves.max { $0.rect.maxX < $1.rect.maxX }
            out.append("nt=\(rect(title?.view)) nl=\(rect(left?.view)) nr=\(rect(right?.view))")
        } else {
            out.append("nb=- nt=- nl=- nr=-")
        }
        out.append("tb=\(Self.drawn(tabBar, in: window) ? rect(tabBar) : "-")")
        return out.joined(separator: " ")
    }

    /// In the window, it and every ancestor shown.
    private static func drawn(_ view: UIView?, in window: UIWindow) -> Bool {
        guard let view, view.window === window else { return false }
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha <= 0.01 { return false }
            current = v.superview
        }
        return view.bounds.width > 0 && view.bounds.height > 0
    }

    private static func find(in view: UIView, where match: (UIView) -> Bool) -> UIView? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if match(view) { return view }
        for sub in view.subviews { if let found = find(in: sub, where: match) { return found } }
        return nil
    }

    /// The bar's shown leaf views narrower than most of it (its items, not its background).
    private static func leaves(of bar: UIView, in window: UIWindow, width: CGFloat) -> [(view: UIView, rect: CGRect)] {
        var found: [(view: UIView, rect: CGRect)] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if view.subviews.isEmpty {
                let r = MobileKeyboardProbe().onScreen(view, in: window)
                if r.width > 2, r.height > 2, r.width < width * 0.8 { found.append((view, r)) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(bar)
        return found
    }
}
#endif
