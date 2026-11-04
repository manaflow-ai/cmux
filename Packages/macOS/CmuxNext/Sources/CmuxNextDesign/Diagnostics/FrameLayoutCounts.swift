public import AppKit

/// `debug.frames`' layout counts per display frame, from ``LayoutPassGuard``'s counters: the `NSView.layout()` calls and
/// window layout passes in each frame, and in DEV and bench builds which window each pass laid out, by its role
/// (``WindowPassTally``: FRAME OWNER S1B finding 4, an extra pass in a borderless window's `NSNextStepFrame`).
@MainActor
public struct FrameLayoutCounts {
    public private(set) var viewLayouts: [Int] = []
    public private(set) var windowLayouts: [Int] = []
    private var mark = (view: 0, window: 0)
    #if DEBUG || CMUX_BENCH_HOOKS
    private var windows = WindowPassTally()
    #endif

    public init() {}

    /// Counts from now.
    public mutating func reset() {
        viewLayouts.removeAll(keepingCapacity: true)
        windowLayouts.removeAll(keepingCapacity: true)
        mark = (LayoutPassGuard.shared.viewLayoutCalls, LayoutPassGuard.shared.windowLayoutPasses)
        #if DEBUG || CMUX_BENCH_HOOKS
        windows.reset()
        #endif
    }

    /// `debug.frames` stopped: no more counting per window.
    public mutating func stop() {
        #if DEBUG || CMUX_BENCH_HOOKS
        windows.stop()
        #endif
    }

    /// One display frame: its counts since the last frame (kept when `records`; the marks always move).
    public mutating func frame(records: Bool) {
        let guardian = LayoutPassGuard.shared
        let passes = guardian.windowLayoutPasses &- mark.window
        if records {
            viewLayouts.append(guardian.viewLayoutCalls &- mark.view)
            windowLayouts.append(passes)
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        windows.frame(windowPasses: passes, records: records)
        #endif
        mark = (guardian.viewLayoutCalls, guardian.windowLayoutPasses)
    }

    /// The `debug.frames` fields, as Foundation values: totals, and with `raw` the per-frame arrays.
    public func report(raw: Bool) -> [String: Any] {
        var report: [String: Any] = ["view_layouts": viewLayouts.reduce(0, +), "view_layouts_max": viewLayouts.max() ?? 0,
                                     "window_layouts": windowLayouts.reduce(0, +)]
        #if DEBUG || CMUX_BENCH_HOOKS
        // Window layout passes by window role: passes, frames with one or more, frames with two or more, the most in a frame.
        report["window_passes"] = windows.roles.mapValues { ["passes": $0.passes, "frames": $0.frames, "frames_2_plus": $0.framesTwoOrMore, "max": $0.max] }
        report["window_passes_no_slot"] = LayoutPassGuard.shared.passesInNoSlot
        if raw { report["window_passes_per_frame"] = windows.perFrame }
        #endif
        if raw { (report["view_layouts_per_frame"], report["window_layouts_per_frame"]) = (viewLayouts, windowLayouts) }
        return report
    }
}

extension Array where Element == Double {
    /// The value at `p` (0...1) of an ascending array, nearest rank; 0 when empty (`debug.frames`' percentiles).
    public func sortedPercentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        return self[Swift.min(count - 1, Int((Double(count - 1) * p).rounded()))]
    }
}
