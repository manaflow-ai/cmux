#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

extension NSWindow {
    /// The center, in window coordinates (bottom-left origin), of the shown view whose accessibility identifier is
    /// `identifier`: of several, the one furthest right and then highest (the top-right pane's). Nil without a match.
    ///
    /// `debug.pointer_hover {identifier:}` aims the ``SyntheticPointer`` here, so a capture can hover a control it
    /// cannot find by row, such as the tab bar's ⌄ (`cmux.tabs.newTabMenu`) or the pane's ⋮ (`cmux.pane.more`).
    public func debugCenter(ofAccessibilityIdentifier identifier: String) -> CGPoint? {
        guard let root = contentView else { return nil }
        var best: CGRect?
        func visit(_ view: NSView) {
            if view.isHidden { return }
            if view.accessibilityIdentifier() == identifier {
                let frame = view.convert(view.bounds, to: nil)
                if best.map({ frame.maxX > $0.maxX + 0.5 || (abs(frame.maxX - $0.maxX) <= 0.5 && frame.maxY > $0.maxY) }) ?? true { best = frame }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best.map { CGPoint(x: $0.midX, y: $0.midY) }
    }
}
#endif
