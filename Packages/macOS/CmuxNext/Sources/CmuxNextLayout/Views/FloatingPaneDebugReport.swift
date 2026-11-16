#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG (`debug.cursor`): `report` with an entry for each floating pane that shows in a window of the app, key
/// or not: its card, the card with its resize band (both in window points from the top left, as `debug.mouse` takes
/// a point), and the zone under the pointer of the layout hover (`content`: the pane's own rectangle, or `none`).
public enum FloatingPaneDebugReport {
    /// DEBUG (`debug.cursor`): the cursor report with the entries of the floating panes that show, and the entries
    /// of each screen (``screens(at:)``). `point` has `x` and `y` in window points from the top left when the
    /// caller gives a point.
    public static func cursor(at point: [String: Double]) -> [String: String] {
        let at = point["x"].flatMap { x in point["y"].map { CGPoint(x: x, y: $0) } }
        return withFloatingPanes(LayoutRootView.debugCursorReport()).merging(screens(at: at)) { $1 }
    }

    static func withFloatingPanes(_ report: [String: String]) -> [String: String] {
        var report = report
        for (window, root) in roots() where window.isVisible {
            let height = window.contentView?.bounds.height ?? window.frame.height
            for screen in root.screenViews.values where !screen.isHidden {
                let pointer = root.context.hoverPointer(window)
                for (pane, card) in screen.floatState.cards where !card.isHidden {
                    let rects = [card.cardBounds, card.bounds].map { fromTop($0, of: card, height: height) }
                    let point = pointer.map { card.convert($0, from: nil) }
                    let zone: String? = point.flatMap { at in card.bounds.contains(at) ? (card.part(at: at).map { "\($0)" } ?? "content") : nil }
                    report["float.\(pane.rawValue)"] = "card=\(rects[0]) reach=\(rects[1]) zone=\(zone ?? "none")"
                }
            }
        }
        return report
    }

    /// DEBUG (`debug.cursor`): each screen of each window of the app, key or not, shown or not, with no
    /// pointer and no key window. One entry `floating.WINDOW.SCREEN` with the model's floating list, back to front, and
    /// one entry `card.WINDOW.SCREEN.PANE` for each pane of the list and each pane with a card: the card and the
    /// pane's host as `none`, `hidden` or `shown`; the card's rectangle and the card with its resize band; and the
    /// rectangles of each zone that shows a cursor. With `point`, each pane's entry has the zone at that point
    /// (`content`: the pane's own rectangle, or `none`), and `hit.WINDOW.SCREEN` names the pane and the zone that a
    /// press there goes to: the front card of the list that has the point. The rectangles and `point` are in
    /// window points from the top left, as `debug.mouse` takes a point.
    static func screens(at point: CGPoint?) -> [String: String] {
        var report: [String: String] = [:]
        for (window, root) in roots() {
            let height = window.contentView?.bounds.height ?? window.frame.height
            let inWindow = point.map { CGPoint(x: $0.x, y: height - $0.y) }
            for (id, screen) in root.screenViews {
                let key = "\(window.windowNumber).\(id.rawValue)"
                let cards = screen.floatState.cards, list = screen.floatState.list.map(\.pane)
                report["floating.\(key)"] = "window=\(window.isVisible ? "shown" : "hidden") key_window=\(window.isKeyWindow)"
                    + " screen=\(state(screen)) floating=\(list.map(\.rawValue))"
                var hit: String?
                // Back to front, so the last card that has the point is the front one. A card with no pane in the list is behind.
                for pane in cards.keys.filter({ !list.contains($0) }).sorted(by: { $0.rawValue < $1.rawValue }) + list {
                    var entry = "card=\(state(cards[pane])) host=\(state(screen.context.hosts[pane]))"
                    if let card = cards[pane] {
                        entry += " rect=\(fromTop(card.cardBounds, of: card, height: height)) reach=\(fromTop(card.bounds, of: card, height: height))"
                        let zones = Dictionary(grouping: card.cursorRects, by: { "\($0.zone)" })
                        let texts: [String] = zones.keys.sorted().map { name in
                            let rects: [String] = (zones[name] ?? []).map { "\(fromTop($0.rect, of: card, height: height))" }
                            return "\(name):" + rects.joined(separator: "+")
                        }
                        entry += " zones=" + texts.joined(separator: ";")
                        if let at = inWindow.map({ card.convert($0, from: nil) }) {
                            let zone = card.bounds.contains(at) ? (card.part(at: at).map { "\($0)" } ?? "content") : "none"
                            entry += " zone=\(zone)"
                            if zone != "none", state(card) == "shown" { hit = "pane=\(pane.rawValue) zone=\(zone)" }
                        }
                    }
                    report["card.\(key).\(pane.rawValue)"] = entry
                }
                if point != nil { report["hit.\(key)"] = hit ?? "none" }
            }
        }
        return report
    }

    /// Each layout root of each window of the app.
    private static func roots() -> [(NSWindow, LayoutRootView)] {
        var found: [(NSWindow, LayoutRootView)] = []
        for window in NSApp.windows {
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                guard let root = view as? LayoutRootView else { stack.append(contentsOf: view.subviews); continue }
                found.append((window, root))
            }
        }
        return found
    }

    /// `rect` of `view` in window points from the top left of a content view `height` points high.
    private static func fromTop(_ rect: CGRect, of view: NSView, height: CGFloat) -> CGRect {
        let inWindow = view.convert(rect, to: nil)
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// `none` for no view, `hidden` for a view that is hidden, has a hidden view above it or is in no window, else `shown`.
    private static func state(_ view: NSView?) -> String {
        guard let view else { return "none" }
        return view.isHiddenOrHasHiddenAncestor || view.window == nil ? "hidden" : "shown"
    }
}
#endif
