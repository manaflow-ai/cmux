public import AppKit

/// ``RenderStats`` per display frame for a frame probe (`debug.frames` with
/// `render: true`). The probe calls ``tick(record:)`` on each display-link
/// frame; a recorded frame keeps the counts since the previous one, as
/// cc::RenderingStatsInstrumentation keeps per-frame counts for a Chrome
/// trace (cc/debug/rendering_stats_instrumentation.cc). The per-owner counts
/// cover the same frames as the sums: from the tick before the first recorded
/// frame to the last recorded one.
@MainActor
public final class RenderFrameLog {
    /// How long an ``arm()`` may take: the first class scan takes seconds in a cold process.
    public static let armDeadline: Duration = .seconds(30)
    public let stats: RenderStats
    private let windows: @MainActor () -> [NSWindow]
    /// Whether this log holds one arm of ``stats``.
    public private(set) var isArmed = false
    /// Per counter (its raw value), one count per recorded frame.
    private var perFrame: [[Int]] = RenderStats.Counter.allCases.map { _ in [] }
    /// The totals at the last counted tick; nil before the first since ``clear()``.
    private var mark: RenderStats.Totals?
    /// Per owner key, its counts at the start and at the end of the recorded frames.
    private var ownerStart: [UInt: RenderStats.Totals] = [:]
    private var ownerEnd: [UInt: RenderStats.Totals] = [:]
    /// Owner names by key, read when a key first shows (they outlive a later arm's reset).
    private var names: [UInt: String] = [:]

    /// - Parameters:
    ///   - stats: the app's one ``RenderStats`` (its hooks are process-wide).
    ///   - windows: the windows ``report(raw:)`` reads for hidden looping animations.
    public init(stats: RenderStats, windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
        self.stats = stats
        self.windows = windows
    }

    /// Holds one arm of ``stats`` and waits until it counts; false in a build
    /// without hooks, or when ``disarm()`` came first.
    public func arm() async -> Bool {
        if !isArmed { isArmed = stats.arm() }
        guard isArmed else { return false }
        let counting = await stats.ready()
        return counting && isArmed
    }

    /// Ends this log's arm. The recorded frames stay reportable until ``clear()``.
    public func disarm() {
        guard isArmed else { return }
        stats.disarm()
        isArmed = false
    }

    /// Drops the recorded frames and the owner counts.
    public func clear() {
        for index in perFrame.indices { perFrame[index].removeAll(keepingCapacity: true) }
        mark = nil
        ownerStart = [:]
        ownerEnd = [:]
    }

    /// One display frame: with `record`, keeps the counts since the previous counted tick.
    public func tick(record: Bool) {
        guard isArmed, stats.isCounting else { return }
        let now = stats.totals
        let owners = stats.ownerTotals()
        if owners.keys.contains(where: { names[$0] == nil }) {
            for owner in stats.owners() { names[owner.key] = owner.name }
        }
        if record, let mark {
            let frame = now - mark
            for counter in RenderStats.Counter.allCases { perFrame[counter.rawValue].append(frame[counter]) }
            ownerEnd = owners
        } else if perFrame[0].isEmpty {
            ownerStart = owners
            ownerEnd = owners
        }
        mark = now
    }

    /// Counts per owner over the recorded frames, most calls first.
    public func owners() -> [(name: String, totals: RenderStats.Totals)] {
        ownerEnd.compactMap { entry -> (name: String, totals: RenderStats.Totals)? in
            let totals = entry.value - (ownerStart[entry.key] ?? RenderStats.Totals())
            guard totals.calls > 0, let name = names[entry.key] else { return nil }
            return (name, totals)
        }
        .sorted { $0.totals.calls > $1.totals.calls }
    }

    /// The `debug.frames` keys, as a `JSONSerialization` graph: `render_armed` (counting now); after a
    /// counted tick since ``clear()``, armed or not, per counter its key (`frame_sets`, `layouts`,
    /// `damage_rects`, `damage_area`, `contents_sets`, `window_calls`, `tracking_area_adds`: the sum over
    /// recorded frames), `<key>_max` (the most in one frame) and with `raw` `<key>_per_frame`;
    /// `render_owners` (the 32 busiest owner classes over the same frames, nonzero counts only);
    /// `hidden_looping_animations` and `hidden_looping_owners` (``RenderStats/hiddenLoopingAnimations(in:)`` now).
    public func report(raw: Bool) -> [String: Any] {
        var report: [String: Any] = ["render_armed": isArmed && stats.isCounting]
        guard mark != nil else { return report }
        for counter in RenderStats.Counter.allCases {
            let frames = perFrame[counter.rawValue]
            report[counter.key] = frames.reduce(0, &+)
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
