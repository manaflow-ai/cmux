public import QuartzCore

/// `debug.frames`' cause of each missed refresh, from cmux's own stamps (Instruments' Animation Hitches records nothing
/// on the bench's virtual display). Times are `CACurrentMediaTime` seconds.
///
/// Each display-link frame has a deadline: its `targetTimestamp`, when the frame it starts is due on screen. The main
/// run loop reports each turn that ends (``turnEnded(woke:mainEnd:commitEnd:)``): when it woke, when its main work
/// ended (just before Core Animation's commit, the frame presenter's pass counted as commit) and when the commit ended.
/// The first turn that runs across a frame's deadline says why that frame was late: its main work was still running
/// (`main_late`), or its main work was done and the commit was still running (`commit_late`). When the next frame's
/// tick comes more than 1.5 refresh periods after this one's (a missed refresh, as `debug.frames` counts `missed`), the
/// frame is late for that cause; with no turn across the deadline the main thread was idle at it, and the frame still
/// missed: `presented_late` (the render server or the display).
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
    /// (seconds; 0 when unknown: no miss is judged). Closes the previous frame.
    public mutating func tick(timestamp: CFTimeInterval, target: CFTimeInterval, refresh: Double) {
        if lastTick > 0, refresh > 0, let deadline, timestamp - lastTick > refresh * 1.5 {
            let cause = atDeadline ?? .presentedLate
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
