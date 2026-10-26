import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

/// FrameSequenceTracker (p09-observability 057) on synthetic link ticks: a sequence counts the refreshes between
/// its ticks as expected frames and each tick as a committed one, as Chrome's `cc::FrameSequenceTracker` counts
/// BeginFrames against presented frames (cc/metrics/frame_sequence_tracker.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSequenceTrackerTests {
    private static let base: CFTimeInterval = 1000

    /// A motion of 30 frames with `drops` refreshes missed in the middle, at 60 and 120 Hz, with link jitter:
    /// the report and the `frame.sequence` ring summary count exactly those drops.
    @Test(arguments: [60.0, 120.0], [UInt32(0), 1, 5])
    func motionCountsDroppedRefreshes(hz: Double, drops: UInt32) throws {
        let rig = SequenceRig()
        let interval = 1 / hz
        for frame in 0..<30 {
            let refresh = Double(frame) + (frame >= 15 ? Double(drops) : 0)
            let jitter = (frame % 2 == 0 ? 0.1 : -0.1) * interval
            rig.tracker.frameBegan((Self.base + refresh * interval + jitter, interval), motion: true)
        }
        #expect(rig.tracker.isOpen)
        rig.tracker.frameBegan((Self.base + Double(31 + drops) * interval, interval), motion: false)
        #expect(!rig.tracker.isOpen, "the motion stayed open after its last animating tick")
        let (kind, report) = try #require(rig.ends.only)
        #expect(kind == .motion)
        #expect(report.expected == 30 + drops && report.produced == 30)
        #expect(report.dropped == drops)
        let percent = (Int64(drops) * 100 + Int64(30 + drops) - 1) / Int64(30 + drops)
        #expect(report.droppedPercent == percent)
        let summary = try #require(rig.log.records(.frameSequence).only)
        #expect(summary.arg0 == UInt64(30 + drops) && summary.arg1 == 30)
    }

    /// A commit window at 60 and 120 Hz: it ends once it expects 3 frames, with the refreshes its ticks missed
    /// (0, 1 or 5) dropped.
    @Test(arguments: [60.0, 120.0], [UInt32(0), 1, 5])
    func commitWindowCountsDroppedRefreshes(hz: Double, drops: UInt32) throws {
        let rig = SequenceRig()
        let interval = 1 / hz
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        var refresh = 1.0
        while rig.tracker.isCommitWindowOpen {
            rig.tracker.frameBegan((Self.base + refresh * interval, interval), motion: false)
            refresh += refresh == 1 ? 1 + Double(drops) : 1
            #expect(refresh < 20, "the commit window never closed")
            if refresh >= 20 { break }
        }
        let (kind, report) = try #require(rig.ends.only)
        #expect(kind == .commitWindow)
        #expect(report.dropped == drops)
        #expect(report.expected == max(FrameSequenceTracker.commitWindowFrames, 2 + drops))
        #expect(report.produced == report.expected - drops)
    }

    /// The commit's turn held main past 5 refreshes: the first tick after it expects 6 frames and drops 5.
    @Test(arguments: [60.0, 120.0])
    func aBlockedCommitDropsTheRefreshesBeforeItsFirstTick(hz: Double) throws {
        let rig = SequenceRig()
        let interval = 1 / hz
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        rig.tracker.frameBegan((Self.base + 6 * interval, interval), motion: false)
        let (_, report) = try #require(rig.ends.only)
        #expect(report.expected == 6 && report.produced == 1 && report.dropped == 5)
    }

    /// A commit inside an open window extends it by 3 frames.
    @Test func aCommitInsideTheWindowExtendsIt() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        rig.tracker.frameBegan((Self.base + interval, interval), motion: false)
        rig.tracker.commitDidLand(at: Self.base + 1.3 * interval)
        for refresh in 2...3 { rig.tracker.frameBegan((Self.base + Double(refresh) * interval, interval), motion: false) }
        #expect(rig.tracker.isCommitWindowOpen, "the second commit did not extend the window")
        rig.tracker.frameBegan((Self.base + 4 * interval, interval), motion: false)
        let (_, report) = try #require(rig.ends.only)
        #expect(report.expected == 4 && report.produced == 4)
    }

    /// Closed and not animating, ticks open nothing, report nothing and write nothing.
    @Test func closedTicksDoNothing() {
        let rig = SequenceRig()
        for refresh in 0..<10 {
            rig.tracker.frameBegan((Self.base + Double(refresh) / 60, 1.0 / 60), motion: false)
            rig.tracker.frameBegan(nil, motion: false)
        }
        #expect(!rig.tracker.isOpen)
        #expect(rig.ends.reports.isEmpty)
        #expect(rig.log.records.isEmpty)
        rig.tracker.closeAll()
        #expect(rig.ends.reports.isEmpty)
    }

    /// A stall tick has no vsync: the gap across it is not dropped frames, and it ends a commit window.
    @Test func stallTicksCountNothing() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.frameBegan((Self.base, interval), motion: true)
        rig.tracker.frameBegan(nil, motion: true)
        rig.tracker.frameBegan((Self.base + 30 * interval, interval), motion: true)
        rig.tracker.closeAll()
        let (_, motion) = try #require(rig.ends.only)
        #expect(motion.expected == 2 && motion.produced == 2)

        rig.tracker.commitDidLand(at: Self.base + 40 * interval)
        rig.tracker.frameBegan(nil, motion: false)
        #expect(!rig.tracker.isCommitWindowOpen, "a stall tick kept the commit window open")
        #expect(rig.ends.reports.count == 1, "a window that counted no frame was reported")
    }

    /// Runs shorter than 100 expected frames carry into the next run's smoothness sample, as Chrome merges short
    /// sequences (`kMinFramesForThroughputMetric`).
    @Test func shortRunsCarryIntoTheNextSample() {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        var time = Self.base
        func run(frames: Int) {
            for _ in 0..<frames {
                rig.tracker.frameBegan((time, interval), motion: true)
                time += interval
            }
            rig.tracker.frameBegan((time, interval), motion: false)
            time += interval
        }
        run(frames: 60)
        #expect(rig.tracker.unreportedMotion == FrameSequenceReport(expected: 60, produced: 60))
        run(frames: 60)
        #expect(rig.tracker.unreportedMotion == FrameSequenceReport(), "120 frames were not sampled")
        #expect(rig.ends.reports.count == 2)
    }

    /// On a scheduler: an animation client's ticks form one motion sequence that ends when the scheduler leaves
    /// its display, and a commit keeps an idle scheduler ticking for the window, then lets it go.
    @Test func schedulerOpensMotionAndCommitWindows() throws {
        let now = MediaNow()
        let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { now.value }) { _ in SequenceLink() }
        let ends = EndBox()
        scheduler.sequences.onSequenceEnd = { ends.reports.append(($0, $1)) }
        let interval = 1.0 / 120
        let frames = TickCount()
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in
            frames.value += 1
            return frames.value < 10
        }
        spring.activate()
        for refresh in 0..<12 where scheduler.hasLink {
            let skipped = refresh >= 5 ? 1.0 : 0
            scheduler.frameDidFire(timestamp: Self.base + (Double(refresh) + skipped) * interval, refreshInterval: interval)
        }
        #expect(!scheduler.hasLink, "the scheduler kept its link after the spring rested")
        let (kind, motion) = try #require(ends.only)
        #expect(kind == .motion)
        #expect(motion.produced == 10 && motion.dropped == 1)

        now.value = Self.base + 20.3 * interval
        scheduler.noteCommit()
        #expect(scheduler.hasLink, "a commit did not keep the scheduler ticking")
        for refresh in 21..<30 where scheduler.hasLink {
            scheduler.frameDidFire(timestamp: Self.base + Double(refresh) * interval, refreshInterval: interval)
        }
        #expect(!scheduler.hasLink, "the commit hold outlived its window")
        let commit = try #require(ends.reports.last)
        #expect(commit.0 == .commitWindow)
        #expect(commit.1 == FrameSequenceReport(expected: 3, produced: 3))
    }
}

/// A tracker on a test runtime whose `frame` category records, and the sequences it ended.
@MainActor
private final class SequenceRig {
    let log = SequenceRecordLog()
    let tracker: FrameSequenceTracker
    let ends = EndBox()

    init() {
        let log = self.log
        let trace = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        trace.setCategoryMask(TraceCategories.frame.rawValue)
        tracker = FrameSequenceTracker(trace: trace)
        let ends = self.ends
        tracker.onSequenceEnd = { ends.reports.append(($0, $1)) }
    }
}

@MainActor
private final class EndBox {
    var reports: [(FrameSequenceTracker.Kind, FrameSequenceReport)] = []

    /// The one sequence that ended (nil for none or several).
    var only: (FrameSequenceTracker.Kind, FrameSequenceReport)? { reports.count == 1 ? reports[0] : nil }
}

@MainActor
private final class TickCount {
    var value = 0
}

@MainActor
private final class MediaNow {
    var value: CFTimeInterval = 1000
}

@MainActor
private final class SequenceLink: FrameLink {
    var isPaused = false

    func invalidate() {}
}

/// The records a test runtime wrote.
private nonisolated final class SequenceRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    func records(_ name: SignpostName) -> [TraceRuntime.StubRecord] {
        records.filter { $0.name == name.rawValue }
    }
}

extension Array {
    /// The one element (nil for none or several).
    fileprivate var only: Element? { count == 1 ? first : nil }
}
