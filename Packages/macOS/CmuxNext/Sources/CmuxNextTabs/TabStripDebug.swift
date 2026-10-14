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

    /// Each tab cell's frame in the tab row and its opacity, by x (`debug.motion` `trace_start`).
    public static func tabFrames(in strip: TabStripView) -> [(id: String, frame: CGRect, opacity: Float)] {
        strip.cells.map { (id: $0.key.rawValue, frame: $0.value.frame, opacity: $0.value.layer.opacity) }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The image the strip's hover card shows now (nil: placeholder).
    public static func cardThumbnail(in strip: TabStripView) -> CGImage? { strip.hoverCard.shownThumbnail }
}
