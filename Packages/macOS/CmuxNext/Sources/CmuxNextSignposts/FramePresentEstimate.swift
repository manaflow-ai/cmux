import CmuxNextCompat
public import CmuxNextTrace
public import CoreFoundation

/// The `frame.tick`, `frame.commit` and `frame.present_estimate` trace points (p09-observability 037):
/// each display-link tick, each main run-loop commit once, and for a key flow's commit the first vsync
/// of its own display at or after max(the commit, the flow's `frame.gpu_done` when it waits for one),
/// written with the "estimated" flag.
///
/// macOS gives the app no presentation time for a Core Animation commit, so the present is computed from
/// the display link's vsync targets, as Chrome marks a presentation time that did not come from the display
/// hardware by leaving `kHWClock` off its `gfx::PresentationFeedback` (ui/gfx/presentation_feedback.h).
/// Presentation feedback is per display, as Chrome's is per compositor: a flow is presented only by a tick
/// of the display its window is on, and each `frame.tick` names its display.
///
/// `frame.commit` is written once for each main run-loop turn end while the frame category records, by one
/// repeating observer after Core Animation's commit observer (``observeCommits()``), as Chrome traces each
/// commit once (`ProxyImpl::ScheduledActionCommit`, cc/trees/proxy_impl.cc). It carries the key flows marked
/// for that commit (``markCommit(flow:display:awaitsGPU:)``). While the category is off each turn end and
/// each tick cost one relaxed load (``isRecording``) and nothing else runs.
///
/// A committed flow that no kept vsync target shows asks for one tick of its display (``onNeedsFrame``);
/// a GPU completion learned after the last tick asks again, and so does a tick whose vsync came before a
/// ready flow's gate. A flow still waiting for its GPU asks for none. Each tick of a display counts one
/// waited frame for its committed flows, and one past ``framesToWait`` is dropped unpresented, so a flow
/// keeps an idle link up for at most that many frames, only while recording.
///
/// ```swift
/// // The composition root: one observer for the app's commits, which takes the typing probe's echo commits.
/// displays.presents.pendingCommits = { TypingLatencyProbe.shared.takePresentCommits() }
/// displays.presents.observeCommits()
/// // Or by hand: the frame of a key's echo went to its layer on display `id` this turn.
/// presents.markCommit(flow: flow, display: id)
/// // Each display-link tick (DisplayClock.deliver), only while recording:
/// if presents.isRecording { presents.frameDidTick(display: id, timestamp: tick.timestamp, target: tick.targetTimestamp) }
/// ```
@MainActor
public final class FramePresentEstimate {
    /// Ticks of its display a committed flow waits for its present before it is dropped unpresented.
    public static let framesToWait = 8
    /// Flows that wait at once; the oldest is dropped past it.
    static let capacity = 32
    /// Vsync targets kept per display, newest last: a GPU completion or a commit that the main actor learns
    /// of after a tick whose vsync still shows it is presented at that vsync.
    static let recentTargetCount = 4
    /// The main run-loop order of the commit observer: after Core Animation's commit (2000000),
    /// ``CommitBoundary/order`` and the typing probe's echo commits (2000100), which mark the flows the
    /// commit of this turn carries.
    public static let commitObserverOrder: CFIndex = 2_000_200

    /// The runtime the records go to.
    public let trace: TraceRuntime
    /// Stamps the commits (``TraceClock``: `CLOCK_UPTIME_RAW` nanoseconds, the clock of link timestamps).
    private let clock: TraceClock
    /// ``observeCommits()`` adds the main run-loop observer (false in tests: they call ``turnDidCommit()``).
    private let observesRunLoop: Bool
    private var observer: CFRunLoopObserver?

    /// Asked for one tick of `display` (a `CGDirectDisplayID`) while a committed flow there waits for a
    /// vsync that shows it (the display clock points it at its link of that display).
    public var onNeedsFrame: (@MainActor (_ display: UInt32) -> Void)?
    /// The key flows the commit ending this turn carries, from a source that marks them before the commit
    /// observer runs (the typing probe's echo commits); asked at each turn end while recording.
    public var pendingCommits: (@MainActor () -> [Commit])?

    /// A key flow's frame that went to its layer on a display (``pendingCommits``).
    public nonisolated struct Commit: Sendable, Hashable {
        public let flow: UInt64
        /// The `CGDirectDisplayID` of the flow's window.
        public let display: UInt32
        /// Its GPU work finishes later (``markCommit(flow:display:awaitsGPU:)``).
        public let awaitsGPU: Bool

        public init(flow: UInt64, display: UInt32, awaitsGPU: Bool = false) {
            self.flow = flow
            self.display = display
            self.awaitsGPU = awaitsGPU
        }
    }

    /// A flow on its way to the screen.
    private struct Waiting {
        let flow: UInt64
        let display: UInt32
        let awaitsGPU: Bool
        /// When its commit ended; nil until the turn end it was marked in.
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
    /// The last ``recentTargetCount`` vsync targets of each display, in trace nanoseconds, oldest first.
    private var recentTargets: [UInt32: [UInt64]] = [:]

    /// - Parameters:
    ///   - trace: The runtime the records go to (the app's; tests pass their own).
    ///   - clock: Stamps the commits (tests inject one).
    ///   - observesRunLoop: ``observeCommits()`` adds its main run-loop observer (tests pass false).
    public init(trace: TraceRuntime = .shared, clock: TraceClock = TraceClock(), observesRunLoop: Bool = true) {
        self.trace = trace
        self.clock = clock
        self.observesRunLoop = observesRunLoop
        waiting.reserveCapacity(Self.capacity)
    }

    /// Whether the frame category records now: one relaxed load (the bit folds to a constant).
    @inlinable
    public var isRecording: Bool { trace.isEnabled(categoryBit: SignpostCategory.frame.traceBit) }

    /// Flows waiting for their present (tests and the debug view).
    public var waitingFlows: [UInt64] { waiting.map(\.flow) }

    /// Adds the one main run-loop observer that ends each turn's commit (``turnDidCommit()``), once. A
    /// run-loop observer has no async equivalent; it holds this object weakly and goes away with it.
    public func observeCommits() {
        guard observesRunLoop, observer == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Self.commitObserverOrder) { [weak self] own, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated {
                guard let self else {
                    if let own { CFRunLoopObserverInvalidate(own) }
                    return
                }
                self.turnDidCommit()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// The frame of key flow `flow` went to its layer on `display` this turn: the commit that ends the turn
    /// carries it (its `frame.commit`), and the first vsync of `display` at or after it is its present.
    ///
    /// - Parameters:
    ///   - flow: The key flow (0: none, ignored).
    ///   - display: The `CGDirectDisplayID` of the flow's window.
    ///   - awaitsGPU: Its GPU work finishes later (a Metal frame handed over before completion): the present
    ///     also waits for ``gpuDidFinish(flow:atNanos:)``.
    public func markCommit(flow: UInt64, display: UInt32, awaitsGPU: Bool = false) {
        guard flow != 0, isRecording, !waiting.contains(where: { $0.flow == flow }) else { return }
        if waiting.count >= Self.capacity { waiting.removeFirst() }
        var entry = Waiting(flow: flow, display: display, awaitsGPU: awaitsGPU)
        if let early = earlyGPU.firstIndex(where: { $0.flow == flow }) {
            entry.gpuNanos = earlyGPU.remove(at: early).nanos
        }
        waiting.append(entry)
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
        if waiting[index].commitNanos != nil { settle() }
    }

    /// The commit at the end of this main run-loop turn (its observer; tests call it): marks the
    /// ``pendingCommits``, writes one `frame.commit` (arg0 the first flow it carries, 0 for none; arg1 how
    /// many it carries) and dates the carried flows' commits.
    public func turnDidCommit() {
        guard isRecording else { return }
        if let pendingCommits {
            for commit in pendingCommits() { markCommit(flow: commit.flow, display: commit.display, awaitsGPU: commit.awaitsGPU) }
        }
        let now = clock.nowNanos()
        var first: UInt64 = 0, carried: UInt64 = 0
        for index in waiting.indices where waiting[index].commitNanos == nil {
            if carried == 0 { first = waiting[index].flow }
            carried += 1
            waiting[index].commitNanos = now
        }
        trace.event(.frameCommit, arg0: first, arg1: carried)
        if carried > 0 { settle() }
    }

    /// One tick of `display`'s link: writes `frame.tick` (arg0 the link timestamp; arg1 the display in the
    /// high 32 bits and the nanoseconds to the vsync target in the low 32), presents the flows on `display`
    /// whose gate the vsync meets, and counts one waited frame for the others. Call it only while
    /// ``isRecording``.
    ///
    /// - Parameters:
    ///   - display: The `CGDirectDisplayID` whose link ticked.
    ///   - timestamp: The tick's link timestamp (`CACurrentMediaTime` seconds).
    ///   - target: When its frame is shown (`CACurrentMediaTime` seconds).
    public func frameDidTick(display: UInt32, timestamp: CFTimeInterval, target: CFTimeInterval) { // perf-hot: 0.5ms frame-tick (while recording)
        let stampNanos = TraceClock.nanos(fromMediaTime: timestamp), targetNanos = TraceClock.nanos(fromMediaTime: target)
        let untilTarget = targetNanos > stampNanos ? min(targetNanos - stampNanos, UInt64(UInt32.max)) : 0
        trace.event(.frameTick, arg0: stampNanos, arg1: UInt64(display) << 32 | untilTarget)
        var targets = recentTargets.removeValue(forKey: display) ?? []
        targets.append(targetNanos)
        if targets.count > Self.recentTargetCount { targets.removeFirst() }
        recentTargets[display] = targets
        var due = false
        var index = waiting.startIndex
        while index < waiting.endIndex {
            guard waiting[index].display == display, waiting[index].commitNanos != nil else {
                index += 1
                continue
            }
            if let gate = waiting[index].gate, targetNanos >= gate {
                present(index, at: targetNanos)
                continue
            }
            waiting[index].framesWaited += 1
            if waiting[index].framesWaited > Self.framesToWait {
                waiting.remove(at: index)
                continue
            }
            if waiting[index].gate != nil { due = true }
            index += 1
        }
        // A flow ready for a later vsync than this one asks for the next tick (at most framesToWait).
        if due { onNeedsFrame?(display) }
    }

    /// Presents each committed flow whose gate a kept vsync target of its display meets, and asks for one
    /// tick of each display where a flow with a gate still waits.
    private func settle() {
        var needsFrame: [UInt32] = []
        var index = waiting.startIndex
        while index < waiting.endIndex {
            let entry = waiting[index]
            guard let gate = entry.gate else {
                index += 1
                continue
            }
            if let target = recentTargets[entry.display]?.lazy.filter({ $0 >= gate }).min() {
                present(index, at: target)
                continue
            }
            if !needsFrame.contains(entry.display) { needsFrame.append(entry.display) }
            index += 1
        }
        for display in needsFrame { onNeedsFrame?(display) }
    }

    private func present(_ index: Int, at targetNanos: UInt64) {
        let flow = waiting.remove(at: index).flow
        trace.event(.framePresentEstimate, arg0: flow, arg1: targetNanos, estimated: true)
    }
}
