public import CmuxNextTrace
import QuartzCore
import CmuxNextMetrics
import CmuxNextSignposts

/// What one closed frame sequence counted: the display refreshes it expected a frame for, and the frames that
/// committed in it (Chrome's `FrameSequenceMetrics::ThroughputData`, cc/metrics/frame_sequence_metrics.h).
public struct FrameSequenceReport: Sendable, Equatable {
    /// Display refreshes (vsyncs) the sequence spanned, one per frame it should have made.
    public var expected: UInt32
    /// Frames the main thread committed in it, at most one per refresh.
    public var produced: UInt32

    /// A report of `expected` refreshes and `produced` frames (an empty one by default).
    public init(expected: UInt32 = 0, produced: UInt32 = 0) {
        self.expected = expected
        self.produced = produced
    }

    /// Refreshes with no frame of the sequence.
    public var dropped: UInt32 { expected > produced ? expected - produced : 0 }

    /// ``dropped`` in percent of ``expected``, rounded up so a single drop shows (0 with nothing expected), as
    /// Chrome's `Graphics.Smoothness.PercentDroppedFrames3` (`FrameSequenceMetrics::ThroughputData`).
    public var droppedPercent: Int64 {
        guard expected > 0 else { return 0 }
        return (Int64(dropped) * 100 + Int64(expected) - 1) / Int64(expected)
    }
}

/// One window's frame sequences (Chrome's `cc::FrameSequenceTracker` and its collection,
/// cc/metrics/frame_sequence_tracker.h, cc/metrics/frame_sequence_tracker_collection.cc): while one is open,
/// each display-link tick of the window's ``FrameScheduler`` counts the refreshes since the previous tick as
/// expected frames and the tick as one committed frame, so a main thread that misses refreshes shows as dropped
/// frames.
///
/// Two kinds open it:
/// - ``Kind/motion``, for the span of a layout `motion.run` (``FrameScheduler/beginMotionSequence()`` to
///   ``FrameScheduler/endMotionSequence()``), on the CPU or the render server, as Chrome starts and stops a
///   tracker for each animation sequence (`FrameSequenceTrackerCollection::StartSequence`). Other animation
///   clients (drags, autoscroll) are not layout motion. It records `smoothness.dropped_pct.motion`; a run shorter
///   than ``minimumReportedFrames`` carries into the next one, as Chrome merges a short sequence into the next of
///   its type (`kMinFramesForThroughputMetric`, cc/metrics/frame_sequence_metrics.cc).
/// - ``Kind/commitWindow``, for ``commitWindowFrames`` refreshes after an action's commit
///   (``FrameScheduler/noteCommit()``), the missed frames of Cmd-T, Cmd-N or Cmd-W (``onSequenceEnd``).
///
/// Each tick an open sequence counts records `frame.interval`, and each sequence that closes writes one
/// `frame.sequence` ring event (arg0 expected, arg1 produced). A tick with no vsync (the stall deadline, a tick
/// between vsyncs) counts nothing; while the window's link still runs for someone who sees it, the vsyncs go on
/// and the next link tick counts all it missed as drops (a main-thread stall that the stall deadline reached main
/// before the link did), as Chrome counts every BeginFrame a stalled main thread missed. When the window is
/// hidden or its link stops or changes, a commit window ends with what it counted and the motion's next link tick
/// starts afresh. While nothing is open, a tick costs one branch (``frameBegan(_:vsyncsGoOn:)``).
@MainActor
public final class FrameSequenceTracker {
    /// What opened a sequence.
    public enum Kind: Sendable, Equatable {
        /// A layout `motion.run`.
        case motion
        /// The refreshes right after an action's commit.
        case commitWindow
    }

    /// A display-link tick: its vsync time and the display's refresh period, in seconds.
    typealias LinkFrame = (timestamp: CFTimeInterval, refreshInterval: Double)

    /// Refreshes a commit window spans (Chrome reads an action's first frames the same way: the
    /// `EventLatency` of its first frame and the drops right after it).
    public static let commitWindowFrames: UInt32 = 3
    /// Expected frames a `smoothness.dropped_pct.motion` sample needs; shorter runs add up until they reach it
    /// (Chrome's `kMinFramesForThroughputMetric`).
    public static let minimumReportedFrames: UInt32 = 100
    /// How far into a refresh a commit's first tick may come and still be that refresh's frame (link timestamps
    /// jitter around the vsync).
    nonisolated static let vsyncSlack = 0.25

    /// Called on main with each sequence that closes after counting a frame (task 056 records a commit window's
    /// drops as `action.missed_frames`).
    public var onSequenceEnd: (@MainActor (Kind, FrameSequenceReport) -> Void)?

    private let trace: TraceRuntime
    private let metrics: Metrics
    /// Bit 0: a motion sequence is open; bit 1: a commit window is.
    private var openMask: UInt8 = 0
    private var motion = Counter()
    private var commit = Counter()
    /// A commit window closes once it expects this many frames (a commit inside one extends it).
    private var commitTarget: UInt32 = 0
    /// The `motion.run` spans open in the window (two layout roots of one window may run at once): the motion
    /// sequence closes when the last ends.
    private var motionRuns = 0
    /// The timestamp of the last link tick an open sequence counted (`frame.interval`'s start); nil whenever
    /// nothing is open, so an idle gap is never an interval.
    private var lastFrame: CFTimeInterval?
    /// Motion frames not yet in a `smoothness.dropped_pct.motion` sample (runs under ``minimumReportedFrames``).
    private(set) var unreportedMotion = FrameSequenceReport()
    /// Keeps the scheduler ticking while a sequence is open (made on the first one that holds a scheduler); it
    /// goes idle in the tick that closes the last one, or when the last motion run ends.
    private var hold: FrameClient?

    private static let motionBit: UInt8 = 1
    private static let commitBit: UInt8 = 2

    /// - Parameter trace: The runtime whose ring takes `frame.sequence` and whose metrics file takes the
    ///   histograms (the app's by default; tests pass their own).
    public init(trace: TraceRuntime = .shared) {
        self.trace = trace
        metrics = Metrics(runtime: trace)
    }

    /// A sequence is open.
    public var isOpen: Bool { openMask != 0 }

    /// A motion sequence is open.
    public var isMotionOpen: Bool { openMask & Self.motionBit != 0 }

    /// A commit window is open.
    public var isCommitWindowOpen: Bool { openMask & Self.commitBit != 0 }

    // MARK: Ticks

    /// The scheduler began a frame: `frame` is its link tick, nil for a tick with no vsync. For such a tick,
    /// `vsyncsGoOn` says whether the window's link still runs and someone sees the window (read only then).
    @inline(__always)
    func frameBegan(_ frame: LinkFrame?, vsyncsGoOn: @autoclosure () -> Bool) { // perf-hot: 0.5ms frame-tick (every frame)
        guard openMask != 0 else { return }
        if let frame, frame.refreshInterval > 0 {
            count(frame)
        } else if !vsyncsGoOn() {
            restart()
        }
    }

    /// The window's display link was made, rebuilt or dropped: the vsyncs before it say nothing about the next.
    func linkDidChange() {
        guard openMask != 0 else { return }
        restart()
    }

    private func count(_ frame: LinkFrame) {
        if let lastFrame, frame.timestamp > lastFrame {
            metrics.record(.frameInterval, Int64(((frame.timestamp - lastFrame) * 1_000_000).rounded()))
        }
        lastFrame = frame.timestamp
        if openMask & Self.motionBit != 0 { motion.count(frame.timestamp, refreshInterval: frame.refreshInterval) }
        if openMask & Self.commitBit != 0 {
            commit.count(frame.timestamp, refreshInterval: frame.refreshInterval)
            if commit.report.expected >= commitTarget { closeCommitWindow() }
        }
    }

    /// No vsync to count from (nobody sees the window, or its link stopped): a commit window ends with what it
    /// counted, and the motion's next link tick starts a new interval.
    private func restart() {
        if openMask & Self.commitBit != 0 { closeCommitWindow() }
        motion.anchor = nil
        lastFrame = nil
    }

    // MARK: Motion

    /// A `motion.run` began in the window: the motion sequence opens unless a run holds it open already; its
    /// first link tick is its first frame.
    func beginMotion() {
        motionRuns += 1
        guard openMask & Self.motionBit == 0 else { return }
        openMask |= Self.motionBit
        motion = Counter()
    }

    /// Opens the motion sequence and keeps `scheduler` ticking until it closes.
    func beginMotion(holding scheduler: FrameScheduler) {
        beginMotion()
        keepTicking(scheduler)
    }

    /// A `motion.run` of the window ended: the last one closes the motion sequence (and lets the scheduler go
    /// idle when no commit window is open).
    func endMotion() {
        guard motionRuns > 0 else { return }
        motionRuns -= 1
        guard motionRuns == 0, openMask & Self.motionBit != 0 else { return }
        closeMotion()
        if openMask == 0 { hold?.deactivate() }
    }

    // MARK: Commits

    /// An action committed at `now` (`CACurrentMediaTime` seconds): opens a commit window for the next
    /// ``commitWindowFrames`` refreshes, or extends the open one by as many.
    func commitDidLand(at now: CFTimeInterval) {
        if openMask & Self.commitBit != 0 {
            commitTarget = commit.report.expected &+ Self.commitWindowFrames
            return
        }
        openMask |= Self.commitBit
        commit = Counter(anchor: now, anchorIsFrame: false)
        commitTarget = Self.commitWindowFrames
    }

    /// Opens a commit window at `now` and keeps `scheduler` ticking until it closes.
    func commitDidLand(at now: CFTimeInterval, holding scheduler: FrameScheduler) {
        commitDidLand(at: now)
        keepTicking(scheduler)
    }

    private func keepTicking(_ scheduler: FrameScheduler) {
        // Motion rate: it counts every display frame.
        // frame-client: ticks while a commit window is open, so the tracker counts main's frames (main state)
        let client = hold ?? FrameClient(owner: "FrameSequenceTracker", isAnimation: false, rate: .motion, on: scheduler) { [weak self] _ in
            self?.isOpen ?? false
        }
        hold = client
        client.activate()
    }

    // MARK: Closing

    /// The scheduler left its display (no client left) or went away: every open sequence ends with what it
    /// counted, and the runs it was open for are forgotten.
    func closeAll() {
        motionRuns = 0
        if openMask & Self.motionBit != 0 { closeMotion() }
        if openMask & Self.commitBit != 0 { closeCommitWindow() }
    }

    private func closeMotion() {
        close(Self.motionBit)
        let report = motion.report
        guard report.expected > 0 else { return }
        unreportedMotion.expected &+= report.expected
        unreportedMotion.produced &+= report.produced
        if unreportedMotion.expected >= Self.minimumReportedFrames {
            metrics.record(.smoothnessDroppedPercent(.motion), unreportedMotion.droppedPercent)
            unreportedMotion = FrameSequenceReport()
        }
        end(.motion, report)
    }

    private func closeCommitWindow() {
        close(Self.commitBit)
        end(.commitWindow, commit.report)
    }

    /// Clears `bit`; with nothing left open the next sequence's first tick starts a new `frame.interval`.
    private func close(_ bit: UInt8) {
        openMask &= ~bit
        if openMask == 0 { lastFrame = nil }
    }

    /// Writes the ring summary and tells ``onSequenceEnd``, unless the sequence saw no link tick to count.
    private func end(_ kind: Kind, _ report: FrameSequenceReport) {
        guard report.expected > 0 else { return }
        trace.event(.frameSequence, arg0: UInt64(report.expected), arg1: UInt64(report.produced))
        onSequenceEnd?(kind, report)
    }

    /// One open sequence's counts and where its next interval starts.
    private struct Counter {
        var report = FrameSequenceReport()
        /// The last tick it counted, or (``anchorIsFrame`` false) the commit it opened at; nil: its next tick is
        /// its first frame (Chrome starts a tracker's count at its first BeginFrame).
        var anchor: CFTimeInterval?
        var anchorIsFrame = true

        /// Counts a link tick at `timestamp`: the refreshes since the anchor are expected, the tick is produced.
        /// From a tick, the gap rounds to whole refreshes (one refresh: no drop; six: five dropped). From a
        /// commit, the first refresh after it is the window's first frame, so a tick in that refresh drops none.
        mutating func count(_ timestamp: CFTimeInterval, refreshInterval: Double) {
            var vsyncs: UInt32 = 1
            if let anchor {
                let refreshes = (timestamp - anchor) / refreshInterval
                if refreshes.isFinite, refreshes > 0 {
                    let whole = anchorIsFrame ? refreshes.rounded() : (refreshes - FrameSequenceTracker.vsyncSlack).rounded(.up)
                    vsyncs = UInt32(min(max(whole, 1), Double(UInt32.max >> 1)))
                }
            }
            report.expected = report.expected.addingReportingOverflow(vsyncs).overflow ? .max : report.expected + vsyncs
            report.produced = report.produced == .max ? .max : report.produced + 1
            anchor = timestamp
            anchorIsFrame = true
        }
    }
}

extension FrameScheduler {
    /// An action committed its change on main (task 056's hook): the window's frame sequences count the next
    /// ``FrameSequenceTracker/commitWindowFrames`` refreshes, and this scheduler ticks through them.
    public func noteCommit() {
        sequences.commitDidLand(at: displayClock.now(), holding: self)
    }

    /// A layout `motion.run` began in this scheduler's window (`LayoutMotionTrace`): its refreshes are a motion
    /// sequence, and this scheduler ticks through it, also while the render server runs the springs. Each call
    /// has one ``endMotionSequence()``.
    public func beginMotionSequence() {
        sequences.beginMotion(holding: self)
    }

    /// The `motion.run` that ``beginMotionSequence()`` began ended.
    public func endMotionSequence() {
        sequences.endMotion()
    }
}
