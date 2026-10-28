#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextWakeups

/// `debug.scroll_frames`: a list's visible rows as the window server composited them,
/// frame after frame, read off the main actor, so a proof sees whether the list kept scrolling while the main
/// thread was stalled (scripts/cmux-next/responsive-scroll-live.py).
///
/// The reply, a JSONSerialization graph: `responsive` (the scroll view's class flag), `point` (the list's
/// center in global display points, top-left origin, where a real gesture goes), `started_ns`
/// (CLOCK_UPTIME_RAW when the reading started, the clock `debug.stall` reports), `frames` ([{ns, changed}]:
/// each frame's share of pixels that differ from the frame before), `origin_before` and `origin_after` (the
/// clip's y), `document_height` and `visible_height`.
@MainActor
public struct ScrollFrameProbe {
    /// The overlay scroller's width at the clip's trailing edge, left out of the crop: its knob shows and
    /// fades on its own.
    private static let scrollerWidth: CGFloat = 16

    public let window: NSWindow
    public let list: NSScrollView

    public init(window: NSWindow, list: NSScrollView) {
        self.window = window
        self.list = list
    }

    /// Moves the list to `scrollTo` (if any), then reads its frames for `duration` ms (50...5000) at `scale`
    /// (0.1...1) on `work`'s system lane. Nil when the list is not on screen in `window`.
    public func run(scrollTo: Double?, duration: Double, scale: Double, work: BackgroundWork) async -> [String: Any]? {
        guard window.windowNumber > 0, var region = window.unitRect(of: list.contentView) else { return nil }
        if let scrollTo {
            list.contentView.scroll(to: NSPoint(x: list.contentView.bounds.minX, y: scrollTo))
            list.reflectScrolledClipView(list.contentView)
        }
        region.size.width = max(0, region.width - Self.scrollerWidth / max(1, window.frame.width))
        let crop = region
        let duration = min(max(duration, 50), 5000), scale = min(max(scale, 0.1), 1)
        let number = CGWindowID(window.windowNumber)
        let before = Double(list.contentView.bounds.minY)
        let screen = window.convertPoint(toScreen: list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil))
        let point = [Double(screen.x), Double((NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)]
        let start = ContinuousClock.now
        let startedNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // The window server reads run back to back on one system lane slot, never on main or the pool.
        let frames = (try? await work.run(.userBlocking, mayBlock: .system) {
            WindowFrame.record(number, scale: scale, crop: crop, from: start, until: duration)
        }) ?? []
        let changes = await WindowFrame.changes(frames)
        let rows: [[String: Any]] = zip(frames, changes).map { frame, changed in
            ["ns": Double(startedNs) + (frame.milliseconds * 1e6).rounded(), "changed": changed]
        }
        return [
            "responsive": type(of: list).isCompatibleWithResponsiveScrolling, "point": point, "started_ns": Double(startedNs),
            "frames": rows, "origin_before": before, "origin_after": Double(list.contentView.bounds.minY),
            "document_height": Double(list.documentView?.frame.height ?? 0), "visible_height": Double(list.contentView.bounds.height),
        ]
    }
}
#endif
