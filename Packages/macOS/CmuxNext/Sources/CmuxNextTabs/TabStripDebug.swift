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
        guard let strip = view as? TabStripView else { return nil }
        // What shows on this frame: the presentation layer, with every Core Animation move in flight.
        var pills = -Double.infinity
        let tabs: [Any] = strip.cells.map { id, cell in
            let shown = strip.shownFrame(cell.layer), opacity = (cell.layer.presentation() ?? cell.layer).opacity
            pills = max(pills, Double(strip.tabsClip.convert(CGPoint(x: shown.maxX, y: 0), to: nil).x))
            return [id.rawValue, Double(shown.minX), Double(shown.width), Double(opacity)] as [Any]
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
}
