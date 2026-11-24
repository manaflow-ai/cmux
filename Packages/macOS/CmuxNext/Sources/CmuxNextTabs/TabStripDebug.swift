public import AppKit

/// Benchmarks (`debug.hover_sweep`, R131): drive a strip's hover path
/// without a real pointer.
@MainActor
public struct TabStripDebug {
    public init() {}

    /// The center of the visible tab at `index` in `strip`'s coordinates.
    public static func tabCenter(in strip: TabStripView, at index: Int) -> CGPoint? {
        let tabs = strip.model.orderedTabs
        guard tabs.indices.contains(index), let cell = strip.cells[tabs[index].id] else { return nil }
        return strip.tabsClip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), to: strip)
    }

    /// The pointer moves to `point`, as a mouse move does.
    public static func pointerMoved(in strip: TabStripView, to point: CGPoint) { strip.updateHover(at: point, moved: true) }

    /// The image the strip's hover card shows now (nil: placeholder).
    public static func cardThumbnail(in strip: TabStripView) -> CGImage? { strip.hoverCard.shownThumbnail }

    /// `debug.motion` `trace_*` (a `MotionFrameTrace` sampler): each tab cell of a strip as
    /// `[id, x, width, opacity]` in the tab row, the strip's width, and `strip_edges`: the strip
    /// in its window as `[minX, maxX, top, pillsMaxX]` (points, top-left origin; `pillsMaxX` the
    /// right edge of its last tab cell as shown), so a split's frames can be checked against the
    /// divider; nil for another view.
    public static func motionSample(_ view: NSView) -> [String: [Any]]? {
        if let toolbar = view as? PaneToolbarView { return controlsSample(toolbar) }
        guard let strip = view as? TabStripView else { return nil }
        // What shows on this frame: the presentation layer, with every Core Animation move in flight.
        var pills = -Double.infinity
        let tabs: [Any] = strip.cells.map { id, cell in
            let shown = cell.layer.presentation() ?? cell.layer
            pills = max(pills, Double(strip.tabsClip.convert(CGPoint(x: shown.frame.maxX, y: 0), to: nil).x))
            return [id.rawValue, Double(shown.frame.minX), Double(shown.frame.width), Double(shown.opacity)] as [Any]
        }
        var sample: [String: [Any]] = ["tabs": tabs, "strip": [Double(strip.bounds.width)]]
        // Shown strips only: a hidden workspace's panes stay in the window.
        if let window = strip.window, !strip.isHiddenOrHasHiddenAncestor {
            let frame = strip.convert(strip.bounds, to: nil)
            let edges = [frame.minX, frame.maxX, window.frame.height - frame.maxY].map { (Double($0) * 100).rounded() / 100 }
            sample["strip_edges"] = [edges + [pills.isFinite ? (pills * 100).rounded() / 100 : 0]]
        }
        return sample
    }

    /// `controls`: a pane's top-right toolbar (lockstep resize, Leo 2026-11-24: "the buttons to track the dragging of
    /// the pane split dividers"), as `[minX, maxX, top, paneMaxX, buttonsMaxX]` in window points (top-left origin):
    /// the toolbar's frame, its pane's right edge (the view it sits in) and the right edge of its rightmost shown
    /// button as the presentation layer shows it this frame. A toolbar that trails its pane shows as
    /// `buttonsMaxX` off `paneMaxX` by more than its resting inset; [:] when hidden.
    static func controlsSample(_ toolbar: PaneToolbarView) -> [String: [Any]]? {
        guard let window = toolbar.window, !toolbar.isHiddenOrHasHiddenAncestor, let pane = toolbar.superview else { return [:] }
        let height = window.frame.height
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        let frame = toolbar.convert(toolbar.bounds, to: nil)
        let paneMaxX = pane.convert(pane.bounds, to: nil).maxX
        var buttonsMaxX = -CGFloat.infinity
        for button in toolbar.buttons + toolbar.nativeButtons + [toolbar.moreButton, toolbar.zoomButton] as [NSView]
        where !button.isHidden && button.superview != nil {
            let layer = button.layer?.presentation() ?? button.layer
            let local = layer.map { CGRect(origin: $0.frame.origin, size: $0.bounds.size) } ?? button.frame
            buttonsMaxX = max(buttonsMaxX, (button.superview ?? toolbar).convert(local, to: nil).maxX)
        }
        let row: [Any] = [rounded(frame.minX), rounded(frame.maxX), rounded(height - frame.maxY), rounded(paneMaxX),
                          buttonsMaxX.isFinite ? rounded(buttonsMaxX) : -1]
        return ["controls": [row]]
    }
}
