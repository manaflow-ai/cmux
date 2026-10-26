public import CmuxNextTrace
public import CoreFoundation

/// The `frame.tick` and `frame.present_estimate` trace points (p09-observability 037): each display-link
/// tick, and for a key flow's commit the first vsync at or after max(the commit, the flow's
/// `frame.gpu_done` when it has one), written with the "estimated" flag.
///
/// macOS gives the app no presentation time for a Core Animation commit, so the present is computed from
/// the link's vsync targets, as Chrome marks a presentation time that did not come from the display
/// hardware by leaving `kHWClock` off its `gfx::PresentationFeedback` (ui/gfx/presentation_feedback.h).
/// A flow that waits for its GPU work (``markCommit(flow:awaitsGPU:)``) is not presented before
/// ``gpuDidFinish(flow:atNanos:)``: a GPU that finishes after a vsync moves the present to a later one.
///
/// Everything records only while the frame category does (a `trace.start` recording): while it does not,
/// ``isRecording`` is one relaxed load and nothing else runs. While a flow waits and the display link is
/// idle, ``onNeedsFrame`` asks for ticks (the app scheduler of the display clock), and a flow that no vsync
/// presents within ``framesToWait`` ticks is dropped, so a waiting flow keeps an idle link up for at most
/// that many frames, and only while recording.
///
/// ```swift
/// // The surface's frame of a key's echo went to its layer:
/// presents.markCommit(flow: flow, awaitsGPU: true)
/// // Its Metal completion handler, passed on to the main actor:
/// presents.gpuDidFinish(flow: flow, atNanos: doneNanos)
/// // Each display-link tick (DisplayClock.deliver), only while recording:
/// if presents.isRecording { presents.frameDidTick(timestamp: tick.timestamp, target: tick.targetTimestamp) }
/// ```
@MainActor
public final class FramePresentEstimate {
    /// Ticks a flow waits for its present before it is dropped unpresented.
    public static let framesToWait = 8
    /// Flows that wait at once; the oldest is dropped past it.
    static let capacity = 32
    /// Vsync targets kept, newest last: a GPU completion or a commit that the main actor learns of after
    /// a tick that already shows it is presented at that tick's vsync.
    static let recentTargetCount = 4

    /// The runtime the records go to.
    public let trace: TraceRuntime
    /// Stamps the commits (``TraceClock``: `CLOCK_UPTIME_RAW` nanoseconds, the clock of link timestamps).
    private let clock: TraceClock
    /// Runs `body` after the commit that ends this turn, which writes `frame.commit` with `flow`
    /// (``CommitBoundary/after(flow:_:)``; tests fire it by hand).
    public typealias AfterCommit = @MainActor (_ flow: UInt64, _ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void

    /// Ends each flow's commit.
    private let afterCommit: AfterCommit
    /// The category bit of every record here (``SignpostCategory/frame``).
    @usableFromInline let frameBit = SignpostCategory.frame.traceBit

    /// Asked while a committed flow waits for a vsync that shows it: tick the display link at least
    /// once more (the composition root points it at a one-shot ``FrameClient`` of the app scheduler).
    public var onNeedsFrame: (@MainActor () -> Void)?

    /// A flow on its way to the screen.
    private struct Waiting {
        let flow: UInt64
        let awaitsGPU: Bool
        /// When its commit ended; nil until its ``CommitBoundary`` fires.
        var commitNanos: UInt64?
        /// When its GPU work finished; nil until it is known.
        var gpuNanos: UInt64?
        var framesWaited = 0

        /// The earliest a vsync can show it; nil while its commit or the GPU work it waits for is to come.
        var gate: UInt64? {
            guard let commitNanos else { return nil }
            if awaitsGPU, gpuNanos == nil { return nil }
            return max(commitNanos, gpuNanos ?? 0)
        }
    }

    private var waiting: [Waiting] = []
    /// GPU completions of flows whose commit was not marked yet, oldest first (at most ``capacity``).
    private var earlyGPU: [(flow: UInt64, nanos: UInt64)] = []
    /// The last ``recentTargetCount`` vsync targets, in trace nanoseconds, oldest first.
    private var recentTargets: [UInt64] = []

    /// - Parameters:
    ///   - trace: The runtime the records go to (the app's; tests pass their own).
    ///   - clock: Stamps the commits (tests inject one).
    ///   - afterCommit: Ends each flow's commit; nil: a ``CommitBoundary`` on `trace`.
    public init(trace: TraceRuntime = .shared, clock: TraceClock = TraceClock(), afterCommit: AfterCommit? = nil) {
        self.trace = trace
        self.clock = clock
        let boundary = CommitBoundary(trace: trace)
        self.afterCommit = afterCommit ?? { flow, body in boundary.after(flow: flow, body) }
        waiting.reserveCapacity(Self.capacity)
        recentTargets.reserveCapacity(Self.recentTargetCount + 1)
    }

    /// Whether the frame category records now: one relaxed load.
    @inlinable
    public var isRecording: Bool { trace.isEnabled(categoryBit: frameBit) }

    /// Flows waiting for their present (tests and the debug view).
    public var waitingFlows: [UInt64] { waiting.map(\.flow) }

    /// The frame of key flow `flow` went to its layer this turn: the commit that ends the turn writes
    /// `frame.commit` with the flow, and the first vsync at or after it writes the flow's present.
    ///
    /// - Parameters:
    ///   - flow: The key flow (0: none, ignored).
    ///   - awaitsGPU: Its GPU work finishes later (a Metal frame): the present also waits for
    ///     ``gpuDidFinish(flow:atNanos:)``.
    public func markCommit(flow: UInt64, awaitsGPU: Bool = false) {
        guard flow != 0, isRecording, !waiting.contains(where: { $0.flow == flow }) else { return }
        if waiting.count >= Self.capacity { waiting.removeFirst() }
        var entry = Waiting(flow: flow, awaitsGPU: awaitsGPU)
        if let early = earlyGPU.firstIndex(where: { $0.flow == flow }) {
            entry.gpuNanos = earlyGPU.remove(at: early).nanos
        }
        waiting.append(entry)
        afterCommit(flow) { [weak self] outcome in self?.commitEnded(flow: flow, outcome) }
    }

    /// The GPU work of flow `flow`'s frame finished at `nanos` (``TraceClock``), known on the main actor
    /// now or later: the present is the first vsync at or after it too.
    public func gpuDidFinish(flow: UInt64, atNanos nanos: UInt64) {
        guard flow != 0, isRecording else { return }
        guard let index = waiting.firstIndex(where: { $0.flow == flow && $0.gpuNanos == nil }) else {
            if earlyGPU.count >= Self.capacity { earlyGPU.removeFirst() }
            earlyGPU.append((flow, nanos))
            return
        }
        waiting[index].gpuNanos = nanos
        if waiting[index].commitNanos != nil { presentOrWait(index) }
    }

    /// One display-link tick: writes `frame.tick` and presents every waiting flow whose gate the tick's
    /// vsync meets. Call it only while ``isRecording``.
    ///
    /// - Parameters:
    ///   - timestamp: The tick's link timestamp (`CACurrentMediaTime` seconds).
    ///   - target: When its frame is shown (`CACurrentMediaTime` seconds).
    public func frameDidTick(timestamp: CFTimeInterval, target: CFTimeInterval) { // perf-hot: 0.5ms frame-tick (while recording)
        let targetNanos = TraceClock.nanos(fromMediaTime: target)
        trace.event(.frameTick, arg0: TraceClock.nanos(fromMediaTime: timestamp), arg1: targetNanos)
        recentTargets.append(targetNanos)
        if recentTargets.count > Self.recentTargetCount { recentTargets.removeFirst() }
        var index = waiting.startIndex
        while index < waiting.endIndex {
            if let gate = waiting[index].gate, targetNanos >= gate {
                present(index, at: targetNanos)
            } else {
                index += 1
            }
        }
    }

    /// One frame of the client that keeps the link up for waiting flows: each waits one frame more,
    /// and one past ``framesToWait`` is dropped unpresented.
    ///
    /// - Returns: Whether a flow still waits (the client ticks again).
    public func frameWaited() -> Bool {
        for index in waiting.indices { waiting[index].framesWaited += 1 }
        waiting.removeAll { $0.framesWaited > Self.framesToWait }
        if waiting.isEmpty { earlyGPU.removeAll() }
        return !waiting.isEmpty
    }

    private func commitEnded(flow: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let index = waiting.firstIndex(where: { $0.flow == flow && $0.commitNanos == nil }) else { return }
        // A missed boundary measured idle time, not a commit: the flow has no present.
        guard outcome == .committed else {
            waiting.remove(at: index)
            return
        }
        waiting[index].commitNanos = clock.nowNanos()
        presentOrWait(index)
    }

    /// Presents the flow at `index` at the earliest recent vsync that meets its gate, or asks for frames.
    private func presentOrWait(_ index: Int) {
        if let gate = waiting[index].gate, let target = recentTargets.lazy.filter({ $0 >= gate }).min() {
            return present(index, at: target)
        }
        onNeedsFrame?()
    }

    private func present(_ index: Int, at targetNanos: UInt64) {
        let flow = waiting.remove(at: index).flow
        trace.event(.framePresentEstimate, arg0: flow, arg1: targetNanos, estimated: true)
    }
}
