public import AppKit

/// Benchmarks (`debug.hover_sweep`, R131): drive a strip's hover path
/// without a real pointer.
@MainActor
public enum TabStripDebug {
    /// The center of the visible tab at `index` in `strip`'s coordinates.
    public static func tabCenter(in strip: TabStripView, at index: Int) -> CGPoint? {
        let tabs = strip.model.orderedTabs
        guard tabs.indices.contains(index), let cell = strip.cells[tabs[index].id] else { return nil }
        return strip.tabsClip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), to: strip)
    }

    /// The pointer moves to `point`, as a mouse move does.
    public static func pointerMoved(in strip: TabStripView, to point: CGPoint) { strip.updateHover(at: point, moved: true) }
}
