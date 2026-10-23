#if DEBUG
import AppKit
import CmuxNextPalette
import CmuxNextSettings

/// `debug.palette.fling {frames?, px?, pointer?}` (DEBUG builds): flings the open palette's list
/// under a resting pointer from inside the app (`PaletteController.debugFling`), so a fleet host
/// with no Post Event grant can measure what a fling costs (perf-lead row 23 test plan step 5;
/// scripts/cmux-next/bench-palette-fling.py). `frames` (default 120, at most 180) display
/// refreshes, `px` points per refresh (default 24, about one row), `pointer` the pointer's place
/// as a fraction of the list's height (default 0.5). Answers the main thread's frame intervals
/// (`frames`, `p50_ms`, `p95_ms`, `max_ms`, `long_frames` over 1.5 refreshes, `refresh_ms`,
/// `display_fps`, `intervals_ms`), the synchronous work per frame (`work_p95_ms`, `work_max_ms`),
/// `scrolled_pt`, `hover_changes`, `hover_misses` (frames whose hovered row was not the row under
/// the pointer) and `palette_renders` (whole-palette renders the fling caused).
struct DebugPaletteFling {
    let services: AppServices

    func run(_ params: [String: JSONValue]) async -> JSONValue {
        guard let report = await services.palette.debugFling(frames: params["frames"]?.intValue ?? 120,
                                                              pointsPerFrame: params["px"]?.doubleValue ?? 24,
                                                              pointerFraction: params["pointer"]?.doubleValue ?? 0.5)
        else { return ["error": "the palette is not open"] }
        let intervals = report.intervalsMs
        return .object([
            "frames": .number(Double(intervals.count)),
            "p50_ms": rank(intervals, 0.5), "p95_ms": rank(intervals, 0.95), "max_ms": rank(intervals, 1),
            "long_frames": .number(Double(report.longFrames)),
            "refresh_ms": .number(report.refreshMs),
            "display_fps": services.palette.visiblePanel?.screen.map { .number(Double($0.maximumFramesPerSecond)) } ?? .null,
            "intervals_ms": .array(intervals.map { .number($0) }),
            "work_p95_ms": rank(report.workMs, 0.95), "work_max_ms": rank(report.workMs, 1),
            "scrolled_pt": .number(report.scrolledPoints),
            "hover_changes": .number(Double(report.hoverChanges)),
            "hover_misses": .number(Double(report.hoverMisses)),
            "palette_renders": .number(Double(report.paletteRenders)),
        ])
    }
}

/// The nearest-rank `fraction` quantile of `values`; null when empty.
private func rank(_ values: [Double], _ fraction: Double) -> JSONValue {
    guard !values.isEmpty else { return .null }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
    return .number(sorted[index])
}
#endif
