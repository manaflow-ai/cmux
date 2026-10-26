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
/// - ``Kind/motion``, while an animation client (a layout spring's driver, the sidebar, an autoscroll) ticks on the
///   scheduler, the span of `motion.run`. It records `smoothness.dropped_pct.motion`; a run shorter than
///   ``minimumReportedFrames`` carries into the next one, as Chrome merges a short sequence into the next of its
///   type (`kMinFramesForThroughputMetric`, cc/metrics/frame_sequence_metrics.cc).
/// - ``Kind/commitWindow``, for ``commitWindowFrames`` refreshes after an action's commit
///   (``FrameScheduler/noteCommit()``), the missed frames of Cmd-T, Cmd-N or Cmd-W (``onSequenceEnd``).
///
/// Each tick an open sequence counts records `frame.interval`, and each sequence that closes writes one
/// `frame.sequence` ring event (arg0 expected, arg1 produced). Stall-deadline ticks have no vsync: they count
/// nothing, end a commit window, and the next link tick starts a new interval. While nothing is open and nothing
/// animates, a tick costs one branch (``frameBegan(_:motion:)``).
@MainActor
public final class FrameSequenceTracker {
    /// What opened a sequence.
    public enum Kind: Sendable, Equatable {
        /// An animation client ticks on the scheduler.
        case motion
        /// The refreshes right after an action's commit.
        case commitWindow
    }

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
    /// The timestamp of the last link tick an open sequence counted (`frame.interval`'s start).
    private var lastFrame: CFTimeInterval?
    /// Motion frames not yet in a `smoothness.dropped_pct.motion` sample (runs under ``minimumReportedFrames``).
    private(set) var unreportedMotion = FrameSequenceReport()
    /// Keeps the scheduler ticking through a commit window (made on the first commit); it goes idle in the tick
    /// that closes the window.
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

    /// A commit window is open.
    public var isCommitWindowOpen: Bool { openMask & Self.commitBit != 0 }

    // MARK: Ticks

    /// The scheduler began a frame: `frame` is its link tick (nil for a stall-deadline tick) and `motion` says
    /// whether an animation client ticks in it. Opens or closes the motion sequence, then counts the tick in each
    /// open sequence.
    @inline(__always)
    func frameBegan(_ frame: (timestamp: CFTimeInterval, refreshInterval: Double)?, motion animating: Bool) { // perf-hot: 0.5ms frame-tick (every frame)
        guard openMask | (animating ? Self.motionBit : 0) != 0 else { return }
        advance(frame, motion: animating)
    }

    private func advance(_ frame: (timestamp: CFTimeInterval, refreshInterval: Double)?, motion animating: Bool) {
        if animating, openMask & Self.motionBit == 0 {
            openMask |= Self.motionBit
            motion = Counter()
        } else if !animating, openMask & Self.motionBit != 0 {
            closeMotion()
        }
        guard openMask != 0 else {
            lastFrame = nil
            return
        }
        guard let frame, frame.refreshInterval > 0 else {
            // No vsync to count from (the link stopped or nobody sees the window): a commit window ends with what
            // it counted, and the motion's next link tick starts afresh.
            if openMask & Self.commitBit != 0 { closeCommitWindow() }
            lastFrame = nil
            motion.anchor = nil
            return
        }
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
        let client = hold ?? FrameClient(owner: "FrameSequenceTracker.commit", isAnimation: false, on: scheduler) { [weak self] _ in
            self?.isCommitWindowOpen ?? false
        }
        hold = client
        client.activate()
    }

    // MARK: Closing

    /// The scheduler left its display (no client left) or went away: every open sequence ends with what it counted.
    func closeAll() {
        guard openMask != 0 else { return }
        if openMask & Self.motionBit != 0 { closeMotion() }
        if openMask & Self.commitBit != 0 { closeCommitWindow() }
        lastFrame = nil
    }

    private func closeMotion() {
        openMask &= ~Self.motionBit
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
        openMask &= ~Self.commitBit
        end(.commitWindow, commit.report)
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
}
