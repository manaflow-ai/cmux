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
/// Two families open it:
/// - An ``Interaction``, from ``FrameScheduler/beginSequence(_:)`` to ``FrameScheduler/endSequence(_:)``, as
///   Chrome starts and stops one tracker per sequence type (`FrameSequenceTrackerCollection::StartSequence`):
///   ``Interaction/motion`` for a layout `motion.run` (on the CPU or the render server; other animation clients,
///   such as autoscroll, are not layout motion), ``Interaction/scroll`` for a terminal or page scroll (a gesture
///   with its momentum, or a wheel's latched ticks: ``ScrollFrameSequences``), ``Interaction/resize`` for a live window resize and
///   ``Interaction/drag`` for a tab drag and its landing. Each records `smoothness.dropped_pct.<type>`; a run
///   shorter than ``minimumReportedFrames`` carries into the next one of its type, as Chrome merges a short
///   sequence into the next of its type (`kMinFramesForThroughputMetric`, cc/metrics/frame_sequence_metrics.cc).
/// - ``Kind/commitWindow``, for ``commitWindowFrames`` refreshes after an action's commit
///   (``FrameScheduler/noteCommit()``), the missed frames of Cmd-T, Cmd-N or Cmd-W (``onSequenceEnd``).
///
/// Each tick an open sequence counts records `frame.interval`, and each sequence that closes writes one
/// `frame.sequence` ring event (arg0 expected, arg1 produced). A tick with no vsync (the stall deadline, a tick
/// between vsyncs) counts nothing; while the window's link still runs for someone who sees it, the vsyncs go on
/// and the next link tick counts all it missed as drops (a main-thread stall that the stall deadline reached main
/// before the link did), as Chrome counts every BeginFrame a stalled main thread missed. When the window is
/// hidden or its link stops or changes, a commit window ends with what it counted and each open interaction's
/// next link tick starts afresh. While nothing is open, a tick costs one branch (``frameBegan(_:vsyncsGoOn:)``).
@MainActor
public final class FrameSequenceTracker {
    /// What opened a sequence.
    public enum Kind: Sendable, Equatable {
        /// A layout `motion.run`.
        case motion
        /// A scroll: a gesture with its momentum, or a wheel's latched ticks.
        case scroll
        /// A live window resize.
        case resize
        /// A tab drag, its landing included.
        case drag
        /// The refreshes right after an action's commit.
        case commitWindow
    }

    /// A span of a person's interaction that `smoothness.dropped_pct.<type>` measures (Chrome's
    /// `FrameSequenceTrackerType`, cc/metrics/frame_sequence_metrics.h).
    public enum Interaction: Int, Sendable, CaseIterable {
        /// A layout `motion.run` (`LayoutMotionTrace`).
        case motion
        /// A terminal or page scroll, a gesture with its momentum or a wheel's latched ticks (``ScrollFrameSequences``).
        case scroll
        /// A live window resize (`LiveResizeWindows`, from will-start to did-end).
        case resize
        /// A tab drag and its landing (`TabDragGhostPanel`, from its show to its close).
        case drag

        /// The kind its sequences end as (``onSequenceEnd``).
        public var kind: Kind {
            switch self {
            case .motion: .motion
            case .scroll: .scroll
            case .resize: .resize
            case .drag: .drag
            }
        }

        /// Its `smoothness.dropped_pct` histogram's type.
        var smoothness: HistogramID.FrameSequence {
            switch self {
            case .motion: .motion
            case .scroll: .scroll
            case .resize: .resize
            case .drag: .drag
            }
        }

        /// Its bit of the open mask.
        var bit: UInt8 { 1 << UInt8(rawValue) }
    }

    /// A display-link tick: its vsync time and the display's refresh period, in seconds.
    typealias LinkFrame = (timestamp: CFTimeInterval, refreshInterval: Double)

    /// Refreshes a commit window spans (Chrome reads an action's first frames the same way: the
    /// `EventLatency` of its first frame and the drops right after it).
    public static let commitWindowFrames: UInt32 = 3
    /// Expected frames a `smoothness.dropped_pct.<type>` sample needs; shorter runs of the type add up until they
    /// reach it (Chrome's `kMinFramesForThroughputMetric`).
    public static let minimumReportedFrames: UInt32 = 100
    /// How far into a refresh a commit's first tick may come and still be that refresh's frame (link timestamps
    /// jitter around the vsync).
    nonisolated static let vsyncSlack = 0.25

    /// Called on main with each sequence that closes after counting a frame (task 056 records a commit window's
    /// drops as `action.missed_frames`).
    public var onSequenceEnd: (@MainActor (Kind, FrameSequenceReport) -> Void)?

    private let trace: TraceRuntime
    private let metrics: Metrics
    /// One bit per open ``Interaction`` (``Interaction/bit``) and ``commitBit`` for an open commit window.
    private var openMask: UInt8 = 0
    /// Each interaction's sequence, indexed by ``Interaction/rawValue``.
    private var interactions = Array(repeating: InteractionSequence(), count: Interaction.allCases.count)
    private var commit = Counter()
    /// A commit window closes once it expects this many frames (a commit inside one extends it).
    private var commitTarget: UInt32 = 0
    /// The timestamp of the last link tick an open sequence counted (`frame.interval`'s start); nil whenever
    /// nothing is open, so an idle gap is never an interval.
    private var lastFrame: CFTimeInterval?
    /// Keeps the scheduler ticking while a sequence is open (made on the first one that holds a scheduler); it
    /// goes idle in the tick that closes the last one, or when the last interaction run ends.
    private var hold: FrameClient?

    private static let commitBit: UInt8 = 1 << 4

    /// - Parameter trace: The runtime whose ring takes `frame.sequence` and whose metrics file takes the
    ///   histograms (the app's by default; tests pass their own).
    public init(trace: TraceRuntime = .shared) {
        self.trace = trace
        metrics = Metrics(runtime: trace)
    }

    /// A sequence is open.
    public var isOpen: Bool { openMask != 0 }

    /// A sequence of `interaction` is open.
    public func isOpen(_ interaction: Interaction) -> Bool { openMask & interaction.bit != 0 }

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
        for index in interactions.indices where openMask & (1 << UInt8(index)) != 0 {
            interactions[index].counter.count(frame.timestamp, refreshInterval: frame.refreshInterval)
        }
        if openMask & Self.commitBit != 0 {
            commit.count(frame.timestamp, refreshInterval: frame.refreshInterval)
            if commit.report.expected >= commitTarget { closeCommitWindow() }
        }
    }

    /// No vsync to count from (nobody sees the window, or its link stopped): a commit window ends with what it
    /// counted, and each open interaction's next link tick starts a new interval.
    private func restart() {
        if openMask & Self.commitBit != 0 { closeCommitWindow() }
        for index in interactions.indices { interactions[index].counter.anchor = nil }
        lastFrame = nil
    }

    // MARK: Interactions

    /// A run of `interaction` began in the window: its sequence opens unless a run holds it open already (two
    /// layout roots of one window may run motion at once); its first link tick is its first frame.
    func begin(_ interaction: Interaction) {
        interactions[interaction.rawValue].runs += 1
        guard openMask & interaction.bit == 0 else { return }
        openMask |= interaction.bit
        interactions[interaction.rawValue].counter = Counter()
    }

    /// Opens `interaction`'s sequence and keeps `scheduler` ticking until it closes.
    func begin(_ interaction: Interaction, holding scheduler: FrameScheduler) {
        begin(interaction)
        keepTicking(scheduler)
    }

    /// A run of `interaction` ended: the last one closes its sequence (and lets the scheduler go idle when
    /// nothing else is open).
    func end(_ interaction: Interaction) {
        let index = interaction.rawValue
        guard interactions[index].runs > 0 else { return }
        interactions[index].runs -= 1
        guard interactions[index].runs == 0, openMask & interaction.bit != 0 else { return }
        close(interaction)
        if openMask == 0 { hold?.deactivate() }
    }

    /// `interaction`'s frames not yet in a `smoothness.dropped_pct` sample (runs under ``minimumReportedFrames``).
    func unreported(_ interaction: Interaction) -> FrameSequenceReport {
        interactions[interaction.rawValue].unreported
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
        let client = hold ?? FrameClient(owner: "FrameSequenceTracker", isAnimation: false, on: scheduler) { [weak self] _ in
            self?.isOpen ?? false
        }
        hold = client
        client.activate()
    }

    // MARK: Closing

    /// The scheduler left its display (no client left) or went away: every open sequence ends with what it
    /// counted, and the runs it was open for are forgotten.
    func closeAll() {
        for interaction in Interaction.allCases {
            interactions[interaction.rawValue].runs = 0
            if openMask & interaction.bit != 0 { close(interaction) }
        }
        if openMask & Self.commitBit != 0 { closeCommitWindow() }
    }

    private func close(_ interaction: Interaction) {
        clear(interaction.bit)
        let index = interaction.rawValue
        let report = interactions[index].counter.report
        guard report.expected > 0 else { return }
        var unreported = interactions[index].unreported
        unreported.expected &+= report.expected
        unreported.produced &+= report.produced
        if unreported.expected >= Self.minimumReportedFrames {
            metrics.record(.smoothnessDroppedPercent(interaction.smoothness), unreported.droppedPercent)
            unreported = FrameSequenceReport()
        }
        interactions[index].unreported = unreported
        end(interaction.kind, report)
    }

    private func closeCommitWindow() {
        clear(Self.commitBit)
        end(.commitWindow, commit.report)
    }

    /// Clears `bit`; with nothing left open the next sequence's first tick starts a new `frame.interval`.
    private func clear(_ bit: UInt8) {
        openMask &= ~bit
        if openMask == 0 { lastFrame = nil }
    }

    /// Writes the ring summary and tells ``onSequenceEnd``, unless the sequence saw no link tick to count.
    private func end(_ kind: Kind, _ report: FrameSequenceReport) {
        guard report.expected > 0 else { return }
        trace.event(.frameSequence, arg0: UInt64(report.expected), arg1: UInt64(report.produced))
        onSequenceEnd?(kind, report)
    }

    /// One interaction's open sequence, its runs, and its frames not yet sampled.
    private struct InteractionSequence {
        var counter = Counter()
        /// The runs open in the window: the sequence closes when the last ends.
        var runs = 0
        var unreported = FrameSequenceReport()
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

    /// A run of `interaction` began in this scheduler's window: its refreshes are a sequence of that type, and this
    /// scheduler ticks through it (also while the render server runs a motion's springs). Each call has one
    /// ``endSequence(_:)`` on the same scheduler.
    public func beginSequence(_ interaction: FrameSequenceTracker.Interaction) {
        sequences.begin(interaction, holding: self)
    }

    /// The run of `interaction` that ``beginSequence(_:)`` began ended.
    public func endSequence(_ interaction: FrameSequenceTracker.Interaction) {
        sequences.end(interaction)
    }

    /// A layout `motion.run` began in this scheduler's window (`LayoutMotionTrace`): ``beginSequence(_:)`` of
    /// ``FrameSequenceTracker/Interaction/motion``.
    public func beginMotionSequence() {
        beginSequence(.motion)
    }

    /// The `motion.run` that ``beginMotionSequence()`` began ended.
    public func endMotionSequence() {
        endSequence(.motion)
    }
}
