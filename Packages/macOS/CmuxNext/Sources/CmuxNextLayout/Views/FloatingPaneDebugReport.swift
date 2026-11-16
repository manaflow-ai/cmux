#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG (`debug.cursor`): an entry for each floating pane that shows in the key window: its card, the card with
/// its resize band (both in the screen view's coordinates), and the zone under the pointer that the layout hover
/// reads (`content`: the pane's own rectangle; `none`: the pointer is not on this pane or on its band).
public enum FloatingPaneDebugReport {
    /// `report` with the entries of the floating panes.
    public static func withFloatingPanes(_ report: [String: String]) -> [String: String] {
        var report = report
        guard let window = NSApp.keyWindow else { return report }
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            guard let root = view as? LayoutRootView else { stack.append(contentsOf: view.subviews); continue }
            for screen in root.screenViews.values where !screen.isHidden {
                let pointer = root.context.hoverPointer(window).map { screen.convert($0, from: nil) }
                for (pane, card) in screen.floatState.cards where !card.isHidden {
                    let zone = pointer.flatMap { point -> String? in
                        guard card.frame.contains(point) else { return nil }
                        return card.part(at: card.convert(point, from: screen)).map { "\($0)" } ?? "content"
                    }
                    report["float.\(pane.rawValue)"] = "card=\(card.cardFrame) reach=\(card.frame) zone=\(zone ?? "none")"
                }
            }
        }
        return report
    }
}
#endif
