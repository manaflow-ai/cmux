#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextWakeups

/// The main run loop's turns and callout segments, for ``MainJobCensus`` (p08-startup task 080, queue Q11).
///
/// The census's two run-loop observers call ``record(_:at:jobs:)`` at each stage: the first observer of entry,
/// timers, sources, before-waiting, after-waiting and exit, and the last observer of before-waiting and exit. Each
/// call closes the phase that ran since the last one; its time, less the main jobs ``MainJobRing`` timed in it, goes
/// to that phase. A turn starts when the run loop wakes (or with any stage after it slept) and ends after the last
/// before-waiting observer, as ``MainTurnMeter`` counts a turn. What runs between a loop's exit and the next entry
/// (AppKit's event dispatch, `main`, `applicationDidFinishLaunching`) is ``Phase/outside``.
///
/// CFRunLoop runs timers and the main queue after a wake, and blocks and version-0 sources after before-sources
/// (CFRunLoop.c, `__CFRunLoopRun`), so the census knows which kind of callout took a segment's time but not whose
/// it was: a ``Segment`` names a run-loop phase; ``MainJobRing`` names the enqueuers. Chromium's pump watches the
/// same stages with the same observers (base/message_loop/message_pump_apple.mm: `PreSourceObserver`,
/// `PreWaitObserver`, `EnterExitObserver`) and counts what runs outside its tasks as native work
/// (base/task/sequence_manager/thread_controller.h, `RunLevelTracker`).
///
/// Bounded: both lists are reserved at init and stop growing at their capacity (later entries count as dropped), so
/// a turn allocates nothing. Main thread only (its owner's).
public nonisolated struct MainTurnSegments: Sendable {
    /// A stage the census's observers report.
    public enum Activity: Sendable {
        /// A loop starts running (first observer).
        case entry
        /// Before the loop fires its timers (first observer).
        case beforeTimers
        /// Before the loop runs its blocks and version-0 sources (first observer).
        case beforeSources
        /// Before the loop sleeps (first observer): the display cycle and the Core Animation commit follow.
        case beforeWaiting
        /// After every before-waiting observer (last observer): the loop sleeps now.
        case rendered
        /// The loop woke (first observer): its timers, the main queue or a port's message follow.
        case afterWaiting
        /// The loop stops running (first observer): the exit's commit follows.
        case exit
        /// After every exit observer (last observer): the code that ran the loop goes on.
        case exited
    }

    /// What ran in a stretch of a turn.
    public enum Phase: String, Sendable, CaseIterable {
        /// Outside any run loop: `main`, AppKit's event dispatch between `nextEvent` calls.
        case outside = "outside_run_loop"
        case timers = "run_loop.timers"
        /// Blocks and version-0 sources (MainRunLoopBlock posts, the scheduler's turns).
        case sources = "run_loop.sources"
        /// After a wake: timers, the main queue's blocks, a port's message.
        case wake = "run_loop.wake"
        /// The display cycle and the commit.
        case render
        /// The loop sleeps (no turn).
        case asleep
    }

    /// One sources or wake stretch of at least ``segmentFloorNanos`` of its own (main jobs not counted).
    public struct Segment: Sendable, Equatable {
        public var phase: Phase
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        public var startNanos: UInt64
        public var nanos: UInt64
    }

    /// One turn of at least ``turnFloorNanos``.
    public struct Turn: Sendable, Equatable {
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        public var startNanos: UInt64
        public var durationNanos: UInt64 = 0
        // Each phase's time, main jobs not counted.
        var outside: UInt64 = 0
        var timers: UInt64 = 0
        var sources: UInt64 = 0
        var wake: UInt64 = 0
        var render: UInt64 = 0
        /// The main jobs ``MainJobRing`` timed in the turn.
        public var jobs = MainJobRing.Tally()

        public init(startNanos: UInt64) {
            self.startNanos = startNanos
        }

        /// The phase's time in the turn, main jobs not counted.
        public func nanos(_ phase: Phase) -> UInt64 {
            switch phase {
            case .outside: outside
            case .timers: timers
            case .sources: sources
            case .wake: wake
            case .render: render
            case .asleep: 0
            }
        }

        /// Adds `nanos` to `phase` and `tally`'s jobs to the turn's.
        public mutating func add(_ phase: Phase, _ nanos: UInt64, jobs tally: MainJobRing.Tally) {
            switch phase {
            case .outside: outside &+= nanos
            case .timers: timers &+= nanos
            case .sources: sources &+= nanos
            case .wake: wake &+= nanos
            case .render: render &+= nanos
            case .asleep: break
            }
            jobs.jobs += tally.jobs
            jobs.nanos &+= tally.nanos
            if let slot = tally.longestSlot, jobs.longestSlot == nil || tally.longestNanos > jobs.longestNanos {
                jobs.longestSlot = slot
                jobs.longestNanos = tally.longestNanos
            }
        }
    }

    public let turnFloorNanos: UInt64
    public let segmentFloorNanos: UInt64
    public let turnCapacity: Int
    public let segmentCapacity: Int
    public private(set) var turns: [Turn]
    public private(set) var segments: [Segment]
    /// Turns under ``turnFloorNanos``, counted only.
    public private(set) var shortTurns = 0
    public private(set) var droppedTurns = 0
    public private(set) var droppedSegments = 0

    private var phase = Phase.outside
    private var phaseStart: UInt64
    private var current: Turn?

    /// Starts in ``Phase/outside`` at `now` (`main`'s own code before the run loop's first entry is the first turn).
    public init(startingAt now: UInt64, turnCapacity: Int = 2_048, segmentCapacity: Int = 4_096,
                turnFloorNanos: UInt64 = 1_000_000, segmentFloorNanos: UInt64 = 100_000) {
        self.turnCapacity = turnCapacity
        self.segmentCapacity = segmentCapacity
        self.turnFloorNanos = turnFloorNanos
        self.segmentFloorNanos = segmentFloorNanos
        turns = []
        turns.reserveCapacity(turnCapacity)
        segments = []
        segments.reserveCapacity(segmentCapacity)
        phaseStart = now
        current = Turn(startNanos: now)
    }

    /// Closes the phase that ran since the last stage (`jobs`: the main jobs timed in it) and enters `activity`'s.
    public mutating func record(_ activity: Activity, at now: UInt64, jobs: MainJobRing.Tally) {
        let elapsed = now > phaseStart ? now - phaseStart : 0
        let own = elapsed > jobs.nanos ? elapsed - jobs.nanos : 0
        if phase != .asleep {
            if current == nil { current = Turn(startNanos: phaseStart) }
            current?.add(phase, own, jobs: jobs)
            if phase == .sources || phase == .wake, own >= segmentFloorNanos {
                if segments.count < segmentCapacity {
                    segments.append(Segment(phase: phase, startNanos: phaseStart, nanos: own))
                } else {
                    droppedSegments += 1
                }
            }
        }
        switch activity {
        case .entry, .beforeTimers: phase = .timers
        case .beforeSources: phase = .sources
        case .beforeWaiting, .exit: phase = .render
        case .afterWaiting: phase = .wake
        case .exited: phase = .outside
        case .rendered:
            phase = .asleep
            endTurn(at: now)
        }
        if phase != .asleep, current == nil { current = Turn(startNanos: now) }
        phaseStart = now
    }

    private mutating func endTurn(at now: UInt64) {
        guard var turn = current else { return }
        current = nil
        turn.durationNanos = now > turn.startNanos ? now - turn.startNanos : 0
        if turn.durationNanos < turnFloorNanos {
            shortTurns += 1
        } else if turns.count < turnCapacity {
            turns.append(turn)
        } else {
            droppedTurns += 1
        }
    }
}
#endif
