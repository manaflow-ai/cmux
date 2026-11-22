public import QuartzCore

/// `debug.frames`' cause of each missed refresh, from cmux's own stamps (Instruments' Animation Hitches records nothing
/// on the bench's virtual display). Times are `CACurrentMediaTime` seconds.
///
/// Each display-link frame has a deadline: its `targetTimestamp`, when the frame it starts is due on screen. The main
/// run loop reports each turn that ends (``turnEnded(woke:mainEnd:commitEnd:)``): when it woke, when its main work
/// ended (a stamp just before the frame presenter's pass and Core Animation's commit) and when the turn ended after the
/// commit. The first turn that runs across a frame's deadline says why that frame was late:
/// - `main_late`: its main work was still running. A turn still open when the next frame ticks (the tick runs inside
///   it, so its end is not reported yet) counts here when it woke before the deadline
///   (``tick(timestamp:target:refresh:openTurnWoke:)``).
/// - `commit_late`: its main work was done and the rest of the turn was still running. That rest is the frame
///   presenter's pass, AppKit's layout and drawing inside the commit, and the commit itself.
/// When the next frame's tick comes more than 1.5 refresh periods after this one's (a missed refresh, as `debug.frames`
/// counts `missed`), the frame is late for that cause. With no turn across the deadline the main thread was idle at it,
/// and the frame still missed: `presented_late`. That is the render server or the display, and also a commit that
/// ended just before the deadline, too late for the render server to show its frame in time.
public nonisolated struct FrameMissSplit: Sendable, Equatable {
    public nonisolated enum Cause: String, Sendable, CaseIterable {
        case mainLate = "main_late"
        case commitLate = "commit_late"
        case presentedLate = "presented_late"
    }

    /// One missed refresh: when its frame ticked (ms after the first frame), the interval to the next tick, how late
    /// the next tick came after the frame's deadline, and the cause.
    public nonisolated struct Miss: Sendable, Equatable {
        public var atMs: Double
        public var intervalMs: Double
        public var nextTickAfterTargetMs: Double
        public var cause: Cause
    }

    /// Misses kept with their stamps.
    public static let kept = 32

    public private(set) var counts: [Cause: Int] = [:]
    public private(set) var misses: [Miss] = []
    private var first: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var deadline: CFTimeInterval?
    private var atDeadline: Cause?

    public init() {}

    /// A display-link frame ticked at `timestamp`, due on screen at `target`; `refresh` is the refresh period
    /// (seconds; 0 when unknown: no miss is judged). `openTurnWoke`: when the main turn this tick runs in woke (nil
    /// when unknown); that turn has not ended, so when it woke before the previous frame's deadline it ran across it
    /// with its main work. Closes the previous frame.
    public mutating func tick(timestamp: CFTimeInterval, target: CFTimeInterval, refresh: Double, openTurnWoke: CFTimeInterval?) {
        if lastTick > 0, refresh > 0, let deadline, timestamp - lastTick > refresh * 1.5 {
            let open: Cause? = openTurnWoke.flatMap { $0 <= deadline ? .mainLate : nil }
            let cause = atDeadline ?? open ?? .presentedLate
            counts[cause, default: 0] += 1
            if misses.count < Self.kept {
                misses.append(Miss(atMs: (lastTick - first) * 1_000, intervalMs: (timestamp - lastTick) * 1_000,
                                   nextTickAfterTargetMs: (timestamp - deadline) * 1_000, cause: cause))
            }
        }
        if first == 0 { first = timestamp }
        lastTick = timestamp
        deadline = target
        atDeadline = nil
    }

    /// A main run-loop turn ended: it woke at `woke`, its main work ended at `mainEnd` (nil: it reached no commit) and
    /// its commit at `commitEnd`. The first turn across the open frame's deadline names that frame's cause.
    public mutating func turnEnded(woke: CFTimeInterval, mainEnd: CFTimeInterval?, commitEnd: CFTimeInterval) {
        guard let deadline, atDeadline == nil, woke <= deadline, commitEnd > deadline else { return }
        atDeadline = (mainEnd ?? commitEnd) > deadline ? .mainLate : .commitLate
    }

    /// `missed_split` (a count per cause, every cause present) and `missed_frames` (the first ``kept`` misses).
    public var report: [String: Any] {
        [
            "missed_split": Dictionary(uniqueKeysWithValues: Cause.allCases.map { ($0.rawValue, counts[$0] ?? 0) }),
            "missed_frames": misses.map { miss -> [String: Any] in
                ["at_ms": (miss.atMs * 10).rounded() / 10, "interval_ms": (miss.intervalMs * 100).rounded() / 100,
                 "next_tick_after_target_ms": (miss.nextTickAfterTargetMs * 100).rounded() / 100,
                 "cause": miss.cause.rawValue]
            },
        ]
    }
}
