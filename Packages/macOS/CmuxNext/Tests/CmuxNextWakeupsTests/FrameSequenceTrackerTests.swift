import CmuxNextCompat
import CmuxNextMetrics
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

    /// A motion run of 30 frames with `drops` refreshes missed in the middle, at 60 and 120 Hz, with link jitter:
    /// the report and the `frame.sequence` ring summary count exactly those drops.
    @Test(arguments: [60.0, 120.0], [UInt32(0), 1, 5])
    func motionCountsDroppedRefreshes(hz: Double, drops: UInt32) throws {
        let rig = SequenceRig()
        let interval = 1 / hz
        rig.tracker.beginMotion()
        for frame in 0..<30 {
            let refresh = Double(frame) + (frame >= 15 ? Double(drops) : 0)
            let jitter = (frame % 2 == 0 ? 0.1 : -0.1) * interval
            rig.tracker.frameBegan((Self.base + refresh * interval + jitter, interval), vsyncsGoOn: true)
        }
        #expect(rig.tracker.isMotionOpen)
        rig.tracker.endMotion()
        #expect(!rig.tracker.isOpen, "the motion stayed open after its run ended")
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
            rig.tracker.frameBegan((Self.base + refresh * interval, interval), vsyncsGoOn: true)
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
        rig.tracker.frameBegan((Self.base + 6 * interval, interval), vsyncsGoOn: true)
        let (_, report) = try #require(rig.ends.only)
        #expect(report.expected == 6 && report.produced == 1 && report.dropped == 5)
    }

    /// A commit inside an open window extends it by 3 frames.
    @Test func aCommitInsideTheWindowExtendsIt() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        rig.tracker.frameBegan((Self.base + interval, interval), vsyncsGoOn: true)
        rig.tracker.commitDidLand(at: Self.base + 1.3 * interval)
        for refresh in 2...3 { rig.tracker.frameBegan((Self.base + Double(refresh) * interval, interval), vsyncsGoOn: true) }
        #expect(rig.tracker.isCommitWindowOpen, "the second commit did not extend the window")
        rig.tracker.frameBegan((Self.base + 4 * interval, interval), vsyncsGoOn: true)
        let (_, report) = try #require(rig.ends.only)
        #expect(report.expected == 4 && report.produced == 4)
    }

    /// Closed, ticks open nothing, report nothing and write nothing.
    @Test func closedTicksDoNothing() {
        let rig = SequenceRig()
        for refresh in 0..<10 {
            rig.tracker.frameBegan((Self.base + Double(refresh) / 60, 1.0 / 60), vsyncsGoOn: true)
            rig.tracker.frameBegan(nil, vsyncsGoOn: false)
        }
        #expect(!rig.tracker.isOpen)
        #expect(rig.ends.reports.isEmpty)
        #expect(rig.log.records.isEmpty)
        rig.tracker.closeAll()
        #expect(rig.ends.reports.isEmpty)
    }

    /// A stall-deadline tick while the link still runs for a window someone sees (main blocked past the stall
    /// timeout, and the deadline's hop ran before the link's): the next link tick counts the whole gap, 19 drops in
    /// the motion and in the commit window, as Chrome counts every BeginFrame a stalled main thread missed.
    @Test func aStallTickKeepsTheGapAsDrops() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.beginMotion()
        rig.tracker.frameBegan((Self.base, interval), vsyncsGoOn: true)
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        rig.tracker.frameBegan(nil, vsyncsGoOn: true)
        #expect(rig.tracker.isCommitWindowOpen, "a stall tick ended the commit window")
        rig.tracker.frameBegan((Self.base + 20 * interval, interval), vsyncsGoOn: true)
        let (commitKind, commit) = try #require(rig.ends.only)
        #expect(commitKind == .commitWindow)
        #expect(commit.dropped == 19 && commit.produced == 1)
        rig.tracker.endMotion()
        let (motionKind, motion) = try #require(rig.ends.reports.last)
        #expect(motionKind == .motion)
        #expect(motion.dropped == 19 && motion.produced == 2)
    }

    /// A tick with no vsync to count from (nobody sees the window, or its link stopped): the gap across it is not
    /// dropped frames, and it ends a commit window. A link change does the same.
    @Test func aTickWithNoVsyncsRestartsTheCount() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.beginMotion()
        rig.tracker.frameBegan((Self.base, interval), vsyncsGoOn: true)
        rig.tracker.frameBegan(nil, vsyncsGoOn: false)
        rig.tracker.frameBegan((Self.base + 30 * interval, interval), vsyncsGoOn: true)
        rig.tracker.linkDidChange()
        rig.tracker.frameBegan((Self.base + 60 * interval, interval), vsyncsGoOn: true)
        rig.tracker.endMotion()
        let (_, motion) = try #require(rig.ends.only)
        #expect(motion.expected == 3 && motion.produced == 3)

        rig.tracker.commitDidLand(at: Self.base + 70 * interval)
        rig.tracker.frameBegan(nil, vsyncsGoOn: false)
        #expect(!rig.tracker.isCommitWindowOpen, "a tick with no vsyncs kept the commit window open")
        #expect(rig.ends.reports.count == 1, "a window that counted no frame was reported")
    }

    /// Two runs at once (two layout roots of one window): the motion sequence ends with the last.
    @Test func overlappingRunsAreOneSequence() throws {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        rig.tracker.beginMotion()
        rig.tracker.frameBegan((Self.base, interval), vsyncsGoOn: true)
        rig.tracker.beginMotion()
        rig.tracker.frameBegan((Self.base + interval, interval), vsyncsGoOn: true)
        rig.tracker.endMotion()
        #expect(rig.tracker.isMotionOpen, "the first run's end closed the second's sequence")
        rig.tracker.frameBegan((Self.base + 2 * interval, interval), vsyncsGoOn: true)
        rig.tracker.endMotion()
        let (_, motion) = try #require(rig.ends.only)
        #expect(motion == FrameSequenceReport(expected: 3, produced: 3))
    }

    /// Runs shorter than 100 expected frames carry into the next run's smoothness sample, as Chrome merges short
    /// sequences (`kMinFramesForThroughputMetric`).
    @Test func shortRunsCarryIntoTheNextSample() {
        let rig = SequenceRig()
        let interval = 1.0 / 60
        var time = Self.base
        func run(frames: Int) {
            rig.tracker.beginMotion()
            for _ in 0..<frames {
                rig.tracker.frameBegan((time, interval), vsyncsGoOn: true)
                time += interval
            }
            rig.tracker.endMotion()
            time += interval
        }
        run(frames: 60)
        #expect(rig.tracker.unreportedMotion == FrameSequenceReport(expected: 60, produced: 60))
        run(frames: 60)
        #expect(rig.tracker.unreportedMotion == FrameSequenceReport(), "120 frames were not sampled")
        #expect(rig.ends.reports.count == 2)
    }

    /// The histograms in the metrics file: a commit window closes, the window idles, then a motion runs 120 frames
    /// with 5 refreshes missed. `frame.interval` has one sample per counted tick after the first of each sequence,
    /// each the tick spacing in us, and none for the idle gap; `smoothness.dropped_pct.motion` has one sample, 4%.
    @Test func histogramsCountTickSpacingNotIdleGaps() throws {
        let rig = SequenceRig()
        let store = rig.attachMetrics()
        let interval = 1.0 / 60
        var ticks: [CFTimeInterval] = []
        rig.tracker.commitDidLand(at: Self.base + 0.3 * interval)
        for refresh in 1...3 {
            let time = Self.base + Double(refresh) * interval
            ticks.append(time)
            rig.tracker.frameBegan((time, interval), vsyncsGoOn: true)
        }
        #expect(!rig.tracker.isOpen)
        // Idle: the scheduler ticks for other clients with nothing open.
        for refresh in 4..<600 { rig.tracker.frameBegan((Self.base + Double(refresh) * interval, interval), vsyncsGoOn: true) }
        var expectedIntervals = zip(ticks, ticks.dropFirst()).map { Self.micros($1 - $0) }
        ticks.removeAll()
        rig.tracker.beginMotion()
        for frame in 0..<120 {
            let time = Self.base + Double(1000 + frame + (frame >= 60 ? 5 : 0)) * interval
            ticks.append(time)
            rig.tracker.frameBegan((time, interval), vsyncsGoOn: true)
        }
        rig.tracker.endMotion()
        expectedIntervals += zip(ticks, ticks.dropFirst()).map { Self.micros($1 - $0) }

        let delta = store.delta()
        let frameInterval = try #require(delta.histograms.first { $0.name == HistogramID.frameInterval.name })
        #expect(frameInterval.count == UInt64(expectedIntervals.count))
        #expect(frameInterval.sum == expectedIntervals.reduce(0) { $0 + UInt64($1) })
        let longestTick = Self.micros(6 * interval)
        for bucket in frameInterval.buckets {
            let range = try #require(frameInterval.layout.bucketRange(bucket.index))
            #expect(range.lowerBound <= longestTick, "an idle gap was recorded as a frame interval")
        }
        let smoothness = try #require(delta.histograms.first { $0.name == HistogramID.smoothnessDroppedPercent(.motion).name })
        #expect(smoothness.count == 1)
        #expect(smoothness.sum == 4, "5 of 125 expected frames dropped is 4%")
    }

    /// On a scheduler: a layout motion sequence keeps the scheduler ticking from its begin to its end and counts
    /// its drops, an animation client that is not a layout motion opens none, and a commit keeps an idle scheduler
    /// ticking for the window, then lets it go.
    @Test func schedulerOpensMotionAndCommitWindows() throws {
        let now = MediaNow()
        let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { now.value }) { _ in SequenceLink() }
        let ends = EndBox()
        scheduler.sequences.onSequenceEnd = { ends.reports.append(($0, $1)) }
        let interval = 1.0 / 120
        scheduler.beginMotionSequence()
        #expect(scheduler.hasLink, "a motion sequence did not keep the scheduler ticking")
        for refresh in 0..<10 {
            let skipped = refresh >= 5 ? 1.0 : 0
            scheduler.frameDidFire(timestamp: Self.base + (Double(refresh) + skipped) * interval, refreshInterval: interval)
        }
        scheduler.endMotionSequence()
        #expect(!scheduler.hasLink, "the scheduler kept its link after the motion ended")
        let (kind, motion) = try #require(ends.only)
        #expect(kind == .motion)
        #expect(motion.produced == 10 && motion.dropped == 1)

        let frames = TickCount()
        let autoscroll = FrameClient(owner: "autoscroll", on: scheduler) { _ in
            frames.value += 1
            return frames.value < 5
        }
        autoscroll.activate()
        for refresh in 12..<20 where scheduler.hasLink {
            scheduler.frameDidFire(timestamp: Self.base + Double(refresh) * interval, refreshInterval: interval)
            #expect(!scheduler.sequences.isMotionOpen, "an animation client that is not a layout motion opened one")
        }
        #expect(ends.reports.count == 1)

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

    /// The display's stall deadline ticks a visible scheduler whose link still runs (main was blocked past it): the
    /// next link tick counts the refreshes since the last one as drops.
    @Test func theStallDeadlineKeepsAVisibleSchedulersGap() throws {
        let now = MediaNow()
        let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { now.value }) { _ in SequenceLink() }
        let ends = EndBox()
        scheduler.sequences.onSequenceEnd = { ends.reports.append(($0, $1)) }
        let interval = 1.0 / 60
        scheduler.beginMotionSequence()
        scheduler.frameDidFire(timestamp: Self.base, refreshInterval: interval)
        now.value = Self.base + 0.15
        let display = try #require(scheduler.display)
        scheduler.displayClock.stallTimerFired(display)
        scheduler.frameDidFire(timestamp: Self.base + 20 * interval, refreshInterval: interval)
        scheduler.endMotionSequence()
        let (_, motion) = try #require(ends.only)
        #expect(motion.produced == 2 && motion.dropped == 19)
    }

    private static func micros(_ seconds: CFTimeInterval) -> Int64 { Int64((seconds * 1_000_000).rounded()) }
}

/// A tracker on a test runtime whose `frame` category records, and the sequences it ended.
@MainActor
private final class SequenceRig {
    let log = SequenceRecordLog()
    let trace: TraceRuntime
    let tracker: FrameSequenceTracker
    let ends = EndBox()

    init() {
        let log = self.log
        trace = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        trace.setCategoryMask(TraceCategories.frame.rawValue)
        tracker = FrameSequenceTracker(trace: trace)
        let ends = self.ends
        tracker.onSequenceEnd = { ends.reports.append(($0, $1)) }
    }

    /// A metrics file on the rig's runtime, which the tracker's histograms go to.
    func attachMetrics() -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: trace))
        return store
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
