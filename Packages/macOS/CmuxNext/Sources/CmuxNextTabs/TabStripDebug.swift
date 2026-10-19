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
    /// `[id, x, width, opacity]` in the tab row, and the strip's width; nil for another view.
    public static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let strip = view as? TabStripView else { return nil }
        // What shows on this frame: the presentation layer, with every Core Animation move in flight.
        return ["tabs": strip.cells.map { id, cell in
            let shown = cell.layer.presentation() ?? cell.layer
            return [id.rawValue, Double(shown.frame.minX), Double(shown.frame.width), Double(shown.opacity)] as [Any]
        },
                "strip": [Double(strip.bounds.width)]]
    }
}
