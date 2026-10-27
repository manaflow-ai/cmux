import CmuxNextWakeups

/// libghostty's app ticks at most one per display frame while output streams (p03-rendering-119,
/// plans/cmux-next/chrome-parity/p03-rendering.md, R5 and DC6).
///
/// A wakeup after a quiet spell ticks at once, in its hop's turn. A wakeup less than
/// ``streamWindowNanos`` after the last tick means output streams: the tick waits for the next frame,
/// and the pacer's frame client stays on, so the wakeups that follow set the context's pending flag
/// and make no hop at all (``RuntimeCallbackContext/wake()``). The client stops after
/// ``idleFrames`` frames with no wakeup. While a key a terminal took waits for its echo
/// (``GhosttyTickClass/classForTick()`` is input) the tick never waits, and a key stops the frame
/// pacing at once (``noteTerminalKey()``). Clipboard confirms and writes and close are callbacks of
/// their own (GhosttyRuntimeCallbacks.swift) and never wait for a frame.
///
/// Chrome treats continuous input the same way: a discrete event dispatches at once and continuous
/// ones coalesce to one per frame, dispatched at the begin-frame (`MainThreadEventQueue`,
/// third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc, `IsRafAlignedEvent`
/// and `DispatchRafAlignedInput`); a compositor stops asking for begin-frames once a frame finds no
/// work (`SchedulerStateMachine::BeginFrameNeeded`, cc/scheduler/scheduler_state_machine.cc).
///
/// `debug.wakeups` lists the owner ``owner``: reason `wakeup` for each hop a wakeup made to main,
/// reason `frame` for each frame the client ticked (its scheduler records those).
///
/// ```swift
/// let pacer = GhosttyTickPacer(context: context, frames: mainWork.frames,
///                              isInputTick: { ticks.classForTick() == .input },
///                              tick: { [weak self] post in self?.tick(posted: post) })
/// pacer.wakeupArrived(posted: post) // the wakeup's hop
/// ```
@MainActor
final class GhosttyTickPacer {
    /// The ticks' owner in `debug.wakeups`.
    static let owner = "GhosttyRuntime.tick"
    /// Two ticks closer than one 60 Hz frame mean output streams: the next tick waits for the frame.
    static let streamWindowNanos: UInt64 = 16_666_667
    /// The frames with no wakeup the client stays on for, so a short gap in a stream costs no hop.
    static let idleFrames = 2

    private let context: RuntimeCallbackContext
    private let ledger: WakeupLedger
    private let now: () -> UInt64
    private let isInputTick: @MainActor () -> Bool
    private let tick: @MainActor (MainTaskPost?) -> Void
    private var client: FrameClient?
    /// When the last tick ran (``now`` time); nil before the first.
    private var lastTick: UInt64?
    /// Ticks wait for the frame (``RuntimeCallbackContext/framed`` is set).
    private(set) var isPacing = false
    private var emptyFrames = 0

    /// - Parameters:
    ///   - context: The runtime's callback context: its pending and framed flags.
    ///   - frames: The scheduler whose frames run the paced ticks.
    ///   - ledger: Where hops are counted (`debug.wakeups`).
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (tests: a clock they move).
    ///   - isInputTick: Whether a tick that starts now serves a key a terminal took.
    ///   - tick: Runs one app tick, recorded as `post` (nil: run time only).
    init(context: RuntimeCallbackContext, frames: FrameScheduler, ledger: WakeupLedger = .shared,
         now: @escaping () -> UInt64 = { MainTaskPost.uptimeNanos() },
         isInputTick: @escaping @MainActor () -> Bool, tick: @escaping @MainActor (MainTaskPost?) -> Void) {
        self.context = context
        self.ledger = ledger
        self.now = now
        self.isInputTick = isInputTick
        self.tick = tick
        client = FrameClient(owner: Self.owner, isAnimation: false, on: frames) { [weak self] _ in self?.frame() ?? false }
    }

    /// A wakeup's hop reached main: ticks now, or, while output streams and no key waits for its
    /// echo, leaves the tick to the next frame.
    ///
    /// - Parameter post: When the wakeup came.
    func wakeupArrived(posted post: MainTaskPost?) {
        ledger.record(Self.owner, reason: "wakeup")
        // A frame ran the tick after the wakeup queued this hop.
        guard context.pending.load(ordering: .acquiring) else { return }
        if let lastTick, now() &- lastTick < Self.streamWindowNanos, !isInputTick() { return startPacing() }
        runTick(post)
    }

    /// A terminal took a key: its echo's tick never waits for a frame. Wakeups hop again from now;
    /// the client's next frame runs a tick a wakeup left to it before this and stops.
    func noteTerminalKey() {
        guard isPacing else { return }
        isPacing = false
        context.framed.store(false, ordering: .sequentiallyConsistent)
    }

    private func startPacing() {
        emptyFrames = 0
        guard !isPacing else { return }
        isPacing = true
        context.framed.store(true, ordering: .sequentiallyConsistent)
        client?.activate()
    }

    /// One frame: the tick the frame's wakeups wanted, if any. False when the client stops.
    private func frame() -> Bool {
        if context.pending.load(ordering: .sequentiallyConsistent) {
            emptyFrames = 0
            runTick(nil)
        } else {
            emptyFrames += 1
        }
        if isPacing, emptyFrames < Self.idleFrames { return true }
        isPacing = false
        context.framed.store(false, ordering: .sequentiallyConsistent)
        // A wakeup that saw the client on before that store made no hop: the next frame runs its tick.
        return context.pending.load(ordering: .sequentiallyConsistent)
    }

    private func runTick(_ post: MainTaskPost?) {
        lastTick = now()
        tick(post)
    }
}
