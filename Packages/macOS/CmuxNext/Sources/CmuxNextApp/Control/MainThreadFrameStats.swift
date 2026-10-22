#if DEBUG
import CmuxNextSettings

/// The app main thread's work per display frame (``MainThreadFrameSampler``), as the `main_*`
/// fields of a waited `debug.agent_pane fling`. A frame's busy time is how long the main run loop
/// was awake between two display ticks: everything the main thread did in that frame, AppKit
/// layout and drawing, the Core Animation commit, a Chromium page's child-window frame and clip
/// updates and Chromium's message pump included.
nonisolated struct MainThreadFrameStats: Equatable, Sendable {
    /// One frame: its display tick (media time, s), the main thread's busy time since the
    /// previous tick (s), and the display's refresh period (s; nil for the scheduler's stall tick).
    nonisolated struct Frame: Equatable, Sendable {
        var time: Double
        var busy: Double
        var refresh: Double?
    }

    /// One 120 Hz frame, in ms.
    static let budget120HzMs = 1000.0 / 120.0

    let frames: Int
    let busyP50Ms: Double
    let busyP95Ms: Double
    let busyMaxMs: Double
    /// The 120 Hz frame budgets the main thread overran (``dropped(busyMs:)``, summed over frames).
    let dropped120Hz: Int
    /// The display rate the frames ticked at (median), nil when none was a display tick.
    let refreshHz: Double?

    /// The stats of the frames that ticked within `window` (media time, s), of all without one.
    init(_ all: [Frame], within window: ClosedRange<Double>? = nil) {
        let kept = all.filter { window?.contains($0.time) ?? true }
        let busy = kept.map { $0.busy * 1000 }.sorted()
        frames = busy.count
        busyP50Ms = Self.round2(Self.percentile(busy, 0.5))
        busyP95Ms = Self.round2(Self.percentile(busy, 0.95))
        busyMaxMs = Self.round2(busy.last ?? 0)
        dropped120Hz = busy.reduce(0) { $0 + Self.dropped(busyMs: $1) }
        let refresh = kept.compactMap(\.refresh).filter { $0 > 0 }.sorted()
        refreshHz = refresh.isEmpty ? nil : Self.round2(1 / Self.percentile(refresh, 0.5))
    }

    /// The 120 Hz frames one frame's main-thread work would drop: ⌈busy / 8.33 ms⌉ − 1, at least 0
    /// (8 ms drops none, 9 ms one, 17 ms two). A nanosecond of slack keeps an exact multiple exact.
    static func dropped(busyMs: Double) -> Int {
        guard busyMs > 0, busyMs.isFinite else { return 0 }
        return max(0, Int((busyMs / budget120HzMs - 1e-9).rounded(.up)) - 1)
    }

    /// The media-time span (s) of a scroll whose first and last frame ticked `msAgo` ms before
    /// `receivedAt` (media time, s); nil unless `msAgo` is two such ages, the older first.
    static func window(msAgo: [Double], receivedAt: Double) -> ClosedRange<Double>? {
        guard msAgo.count == 2, let first = msAgo.first, let last = msAgo.last, last >= 0, first >= last else { return nil }
        return (receivedAt - first / 1000)...(receivedAt - last / 1000)
    }

    /// The value at fraction `p` of `sorted` (ascending), index round((n − 1) p); 0 when empty. The
    /// page's own frame stats use the same rule (webviews acpmux/perf.ts `percentile`).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// The reply fields.
    var fields: [String: JSONValue] {
        ["main_frames": .number(Double(frames)), "main_busy_p50_ms": .number(busyP50Ms),
         "main_busy_p95_ms": .number(busyP95Ms), "main_busy_max_ms": .number(busyMaxMs),
         "main_dropped_frames_120hz": .number(Double(dropped120Hz)), "main_refresh_hz": refreshHz.map(JSONValue.number) ?? .null]
    }
}
#endif
