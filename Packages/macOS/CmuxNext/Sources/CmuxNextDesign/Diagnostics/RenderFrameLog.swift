public import AppKit

/// ``RenderStats`` per display frame for a frame probe (`debug.frames` with
/// `render: true`). The probe calls ``tick(record:)`` on each display-link
/// frame; a recorded frame keeps the counts since the previous one, as
/// cc::RenderingStatsInstrumentation keeps per-frame counts for a Chrome
/// trace (cc/debug/rendering_stats_instrumentation.cc).
@MainActor
public final class RenderFrameLog {
    public let stats: RenderStats
    private let windows: @MainActor () -> [NSWindow]
    public private(set) var isArmed = false
    /// Per counter (its raw value), one count per recorded frame.
    private var perFrame: [[Int]] = RenderStats.Counter.allCases.map { _ in [] }
    private var mark = RenderStats.Totals()
    private var ownerMark: [ObjectIdentifier: RenderStats.Totals] = [:]

    public init(stats: RenderStats = RenderStats(layoutGuard: .shared),
                windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
        self.stats = stats
        self.windows = windows
    }

    /// Holds one arm of ``stats`` while `armed`; arming fails in a build without hooks.
    public func setArmed(_ armed: Bool) {
        if armed, !isArmed {
            isArmed = stats.arm()
        } else if !armed, isArmed {
            stats.disarm()
            isArmed = false
        }
    }

    /// Drops the recorded frames; owners count from here.
    public func clear() {
        for index in perFrame.indices { perFrame[index].removeAll(keepingCapacity: true) }
        mark = stats.totals
        ownerMark = Dictionary(stats.owners().map { ($0.id, $0.totals) }, uniquingKeysWith: { first, _ in first })
    }

    /// One display frame: with `record`, keeps the counts since the previous frame.
    public func tick(record: Bool) {
        guard isArmed else { return }
        let now = stats.totals
        if record {
            let frame = now - mark
            for counter in RenderStats.Counter.allCases { perFrame[counter.rawValue].append(frame[counter]) }
        }
        mark = now
    }

    /// Counts per owner since ``clear()``, most calls first.
    public func owners() -> [(name: String, totals: RenderStats.Totals)] {
        stats.owners().compactMap { owner -> (name: String, totals: RenderStats.Totals)? in
            let totals = owner.totals - (ownerMark[owner.id] ?? RenderStats.Totals())
            return totals.calls > 0 ? (owner.name, totals) : nil
        }
        .sorted { $0.totals.calls > $1.totals.calls }
    }

    /// The `debug.frames` keys, as a `JSONSerialization` graph: `render_armed`; armed, per counter its
    /// key (`frame_sets`, `layouts`, `damage_rects`, `damage_area`, `contents_sets`, `window_calls`,
    /// `tracking_area_adds`: the sum over recorded frames), `<key>_max` (the most in one frame) and with
    /// `raw` `<key>_per_frame`; `render_owners` (the 32 busiest owner classes, nonzero counts only);
    /// `hidden_looping_animations` and `hidden_looping_owners` (``RenderStats/hiddenLoopingAnimations(in:)`` now).
    public func report(raw: Bool) -> [String: Any] {
        var report: [String: Any] = ["render_armed": isArmed]
        guard isArmed else { return report }
        for counter in RenderStats.Counter.allCases {
            let frames = perFrame[counter.rawValue]
            report[counter.key] = frames.reduce(0, +)
            report[counter.key + "_max"] = frames.max() ?? 0
            if raw { report[counter.key + "_per_frame"] = frames }
        }
        report["render_owners"] = owners().prefix(32).map { owner -> [String: Any] in
            var entry: [String: Any] = ["owner": owner.name]
            for counter in RenderStats.Counter.allCases where owner.totals[counter] != 0 {
                entry[counter.key] = owner.totals[counter]
            }
            return entry
        }
        let loops = RenderStats.hiddenLoopingAnimations(in: windows())
        report["hidden_looping_animations"] = loops.values.reduce(0, +)
        report["hidden_looping_owners"] = loops
        return report
    }
}
