#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG (`debug.cursor`): an entry for each floating pane that shows in the key window: its card, the card with
/// its resize band (both in window points from the top left, as `debug.mouse` takes a point), and the zone under
/// the pointer that the layout hover reads (`content`: the pane's own rectangle; `none`: not on this pane's band).
public enum FloatingPaneDebugReport {
    /// `report` with the entries of the floating panes.
    public static func withFloatingPanes(_ report: [String: String]) -> [String: String] {
        var report = report
        guard let window = NSApp.keyWindow else { return report }
        let height = window.contentView?.bounds.height ?? window.frame.height
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            guard let root = view as? LayoutRootView else { stack.append(contentsOf: view.subviews); continue }
            for screen in root.screenViews.values where !screen.isHidden {
                let pointer = root.context.hoverPointer(window)
                for (pane, card) in screen.floatState.cards where !card.isHidden {
                    let rects = [card.cardBounds, card.bounds].map { card.convert($0, to: nil) }
                        .map { CGRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height) }
                    let point = pointer.map { card.convert($0, from: nil) }
                    let zone: String? = point.flatMap { at in card.bounds.contains(at) ? (card.part(at: at).map { "\($0)" } ?? "content") : nil }
                    report["float.\(pane.rawValue)"] = "card=\(rects[0]) reach=\(rects[1]) zone=\(zone ?? "none")"
                }
            }
        }
        return report
    }
}
#endif
