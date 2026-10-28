public import AppKit

/// When a main-thread commit reaches the glass: the presented end of an input's latency
/// (plans/cmux-next/chrome-parity/p04-input.md, section I, task 003).
///
/// cmux gets no presentation feedback for AppKit content, so the time is an estimate: the vsync
/// that picks up the commit (the first vsync at or after the commit's end), plus one render-server
/// frame, plus a per-OS constant (``PresentationOffset``, calibrated by the glass check, DC3).
///
/// Chrome closes an `EventLatency` at the frame's presentation feedback, after the fact
/// (`cc/metrics/event_latency_tracker.h`, `gfx::PresentationFeedback` in
/// `ui/gfx/presentation_feedback.h`). The estimate is resolved the same way: a commit is queued
/// and resolved by the first real tick of the window's link after it, snapped onto that tick's
/// `targetTimestamp` grid (`base::TimeTicks::SnappedToNextTick`, `base/time/time.h`, as
/// `viz::DelayBasedTimeSource` does). ``PresentedEstimate/Basis`` says, as `kVSync` does, whether
/// a real tick gave the phase.
///
/// The vsync comes from the display's one link (`ui/display/mac/display_link_mac.h`): the clock
/// never makes a link of its own. ``holdForInput(on:)`` subscribes a ``FrameClient`` to the
/// window's ``FrameScheduler`` (which subscribes to the display's clock) for ``holdFrames`` frames
/// after each tracked input, so that input's commit is resolved by a real tick. A commit with no
/// hold joins the window's link for one frame only when another client already runs it; otherwise
/// it resolves at once from the last phase of the same display, or from the nominal refresh.
@MainActor
public final class PresentationClock {
    /// Frames the window's link stays subscribed after the last tracked input.
    public nonisolated static let holdFrames = 3
    /// How far (either way) a commit may be from a known vsync for that phase to be extended: past
    /// about a second, host-clock and display drift move the phase by a large part of a frame.
    public nonisolated static let maxExtrapolationNanos: UInt64 = 1_000_000_000

    /// The frame scheduler of a window (``FrameScheduler/forWindow(_:)``; a fake in tests).
    public typealias SchedulerForWindow = @MainActor (NSWindow) -> FrameScheduler
    /// The display of a scheduler's window; nil when it has no screen.
    public typealias DisplayForScheduler = @MainActor (FrameScheduler) -> PresentationDisplay?
    /// Receives a commit's estimate once it is resolved.
    public typealias Resolve = @MainActor (PresentedEstimate) -> Void

    private let offset: PresentationOffset
    private let schedulerForWindow: SchedulerForWindow
    private let displayForScheduler: DisplayForScheduler
    private var holds: [ObjectIdentifier: Hold] = [:]

    /// - Parameters:
    ///   - offset: The per-OS constant added to every estimate.
    ///   - scheduler: The scheduler that holds a window's link.
    ///   - display: The display of a scheduler's window.
    public init(offset: PresentationOffset = PresentationOffset(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                scheduler: @escaping SchedulerForWindow = { FrameScheduler.forWindow($0) },
                display: @escaping DisplayForScheduler = { PresentationDisplay(screenOf: $0) }) {
        self.offset = offset
        self.schedulerForWindow = scheduler
        self.displayForScheduler = display
    }

    // MARK: Holding the link

    /// Keeps `window`'s link subscribed for ``holdFrames`` frames from now (a tracked input).
    public func holdForInput(window: NSWindow) {
        holdForInput(on: schedulerForWindow(window))
    }

    /// Keeps `scheduler`'s link subscribed for ``holdFrames`` frames from now. Another input during
    /// the hold restarts the count; the link goes with the last frame of the hold when no other
    /// client is active.
    public func holdForInput(on scheduler: FrameScheduler) { // perf-hot: 0.01ms key-dispatch (every tracked input)
        let hold = self.hold(for: scheduler)
        hold.framesLeft = Self.holdFrames
        hold.client.activate()
    }

    /// The hold of `scheduler`, made on its first use (one allocation per window, not per input).
    private func hold(for scheduler: FrameScheduler) -> Hold {
        if let hold = existingHold(of: scheduler) { return hold }
        let closed = holds.values.filter { $0.scheduler == nil }
        if !closed.isEmpty { holds = holds.filter { $0.value.scheduler != nil } }
        let hold = Hold(scheduler: scheduler, offset: offset)
        holds[ObjectIdentifier(scheduler)] = hold
        for gone in closed { gone.abandon() }
        return hold
    }

    private func existingHold(of scheduler: FrameScheduler) -> Hold? {
        guard let hold = holds[ObjectIdentifier(scheduler)], hold.scheduler === scheduler else { return nil }
        return hold
    }

    // MARK: Estimates

    /// Resolves the presented time of a commit that ended at `commitEndNanos` in `window`.
    public func presented(commitEndNanos: UInt64, window: NSWindow, _ resolve: @escaping Resolve) {
        presented(commitEndNanos: commitEndNanos, on: schedulerForWindow(window), resolve)
    }

    /// Resolves the presented time of a commit that ended at `commitEndNanos` (`CLOCK_UPTIME_RAW`,
    /// as `CommitBoundary.Commit.commitEndNanos`) on `scheduler`'s display.
    ///
    /// Call it at the commit's end (`CommitBoundary.afterCommit`). During a hold, `resolve` runs on
    /// the next real tick with ``PresentedEstimate/Basis/heldVsync``; if the hold ends on stalled
    /// frames only, it runs then with the estimate of ``presented(commitEndNanos:on:)``. With no hold,
    /// a link another client runs is joined for one frame (no new link); with no running link,
    /// `resolve` runs before this returns.
    public func presented(commitEndNanos: UInt64, on scheduler: FrameScheduler, _ resolve: @escaping Resolve) {
        let display = displayForScheduler(scheduler)
        let existing = existingHold(of: scheduler)
        existing?.note(display)
        guard existing?.client.isActive == true || scheduler.isRunning else {
            resolve(Self.estimateNow(commitEndNanos: commitEndNanos, anchor: existing?.anchor, display: display, offset: offset))
            return
        }
        let hold = existing ?? self.hold(for: scheduler)
        hold.note(display)
        if !hold.client.isActive {
            // Another client runs the link: ride its next frame, no new link.
            hold.framesLeft = 1
            hold.client.activate()
        }
        hold.queue(commitEndNanos, resolve)
    }

    /// The estimate available now for a commit that ended at `commitEndNanos` in `window`.
    public func presented(commitEndNanos: UInt64, window: NSWindow) -> PresentedEstimate {
        presented(commitEndNanos: commitEndNanos, on: schedulerForWindow(window))
    }

    /// The estimate available now, with no tick after the commit: the last real vsync of the same
    /// display extended (``PresentedEstimate/Basis/extrapolated``) while it is within
    /// ``maxExtrapolationNanos``, otherwise the nominal refresh. Never
    /// ``PresentedEstimate/Basis/heldVsync``: an input's commit uses the resolving overload.
    /// Starts no link and subscribes no client.
    public func presented(commitEndNanos: UInt64, on scheduler: FrameScheduler) -> PresentedEstimate {
        let display = displayForScheduler(scheduler)
        let hold = existingHold(of: scheduler)
        hold?.note(display)
        return Self.estimateNow(commitEndNanos: commitEndNanos, anchor: hold?.anchor, display: display, offset: offset)
    }

    /// The refresh interval used with no display (a 60 Hz panel).
    nonisolated static let fallbackRefreshInterval: Double = 1.0 / 60.0

    /// The estimate from a real tick's vsync: the commit snapped onto the tick's grid, plus a frame.
    nonisolated static func estimate(commitEndNanos: UInt64, tick anchor: PhaseAnchor, offset: PresentationOffset) -> PresentedEstimate {
        let vsync = Self.vsync(atOrAfter: commitEndNanos, anchor: anchor.vsyncNanos, interval: anchor.refreshNanos)
        let held = Self.distance(vsync, anchor.vsyncNanos) <= UInt64(holdFrames) * anchor.refreshNanos
        return PresentedEstimate(nanos: offset.applied(to: vsync + anchor.refreshNanos), basis: held ? .heldVsync : .extrapolated,
                                 refreshNanos: anchor.refreshNanos, isVariableRefresh: anchor.display?.isVariableRefresh ?? false)
    }

    /// The estimate with no tick after the commit (see ``presented(commitEndNanos:on:)``).
    nonisolated static func estimateNow(commitEndNanos: UInt64, anchor: PhaseAnchor?, display: PresentationDisplay?,
                                        offset: PresentationOffset) -> PresentedEstimate {
        let isVariableRefresh = display?.isVariableRefresh ?? false
        if let anchor, let display, anchor.display == display,
           Self.distance(commitEndNanos, anchor.vsyncNanos) <= maxExtrapolationNanos {
            let vsync = Self.vsync(atOrAfter: commitEndNanos, anchor: anchor.vsyncNanos, interval: anchor.refreshNanos)
            return PresentedEstimate(nanos: offset.applied(to: vsync + anchor.refreshNanos), basis: .extrapolated,
                                     refreshNanos: anchor.refreshNanos, isVariableRefresh: isVariableRefresh)
        }
        // No phase known: on average the next vsync is half a frame away.
        let interval = Self.nanos(display?.minimumRefreshInterval ?? Self.fallbackRefreshInterval)
        return PresentedEstimate(nanos: offset.applied(to: commitEndNanos + interval / 2 + interval), basis: .nominal,
                                 refreshNanos: interval, isVariableRefresh: isVariableRefresh)
    }

    /// The first vsync at or after `time`, on the grid `anchor + k * interval`
    /// (`base::TimeTicks::SnappedToNextTick`).
    nonisolated static func vsync(atOrAfter time: UInt64, anchor: UInt64, interval: UInt64) -> UInt64 {
        if time <= anchor { return anchor - (anchor - time) / interval * interval }
        return anchor + (time - anchor + interval - 1) / interval * interval
    }

    nonisolated static func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    /// Seconds (`CACurrentMediaTime` base, which is `CLOCK_UPTIME_RAW`) as nanoseconds.
    nonisolated static func nanos(_ seconds: Double) -> UInt64 {
        seconds > 0 ? UInt64((seconds * 1e9).rounded()) : 0
    }

    /// A real vsync of a display: a tick's `targetTimestamp`, its refresh interval and the display it
    /// came from (an anchor of another display, or of a changed refresh range, is never extended).
    struct PhaseAnchor: Sendable, Hashable {
        var vsyncNanos: UInt64
        var refreshNanos: UInt64
        var display: PresentationDisplay?
    }

    /// A commit waiting for the next real tick.
    private struct PendingCommit {
        var commitEndNanos: UInt64
        var resolve: Resolve
    }

    /// The link subscription of one window: a non-animation client that resolves the commits queued
    /// before each real tick and goes idle after the hold's last frame.
    @MainActor
    private final class Hold {
        weak var scheduler: FrameScheduler?
        let offset: PresentationOffset
        var framesLeft = 0
        /// The display the recorded ticks belong to.
        private(set) var display: PresentationDisplay?
        /// The last real tick's vsync; nil before one, or after the display changed.
        private(set) var anchor: PhaseAnchor?
        private var pending: [PendingCommit] = []
        private var resolving: [PendingCommit] = []
        /// Weak both ways: a closed window's scheduler goes with its window, and the hold goes with the clock.
        // Motion rate: it phases every display frame.
        // frame-client: resolves the queued commits against each real tick's vsync for a few frames (main state)
        private(set) lazy var client: FrameClient = FrameClient(owner: "PresentationClock.hold", isAnimation: false, rate: .motion,
                                                   scheduler: { [weak self] in self?.scheduler ?? .app }) { [weak self] tick in
            self?.record(tick) ?? false
        }

        init(scheduler: FrameScheduler, offset: PresentationOffset) {
            self.scheduler = scheduler
            self.offset = offset
        }

        /// The window is on `display` now: a phase of another display (or refresh range) is dropped.
        func note(_ display: PresentationDisplay?) {
            guard display != self.display else { return }
            self.display = display
            anchor = nil
        }

        func queue(_ commitEndNanos: UInt64, _ resolve: @escaping Resolve) {
            pending.append(PendingCommit(commitEndNanos: commitEndNanos, resolve: resolve))
        }

        /// The window went away: resolves what waits with no tick (a nominal estimate).
        func abandon() {
            framesLeft = 0
            resolvePending { commit in
                PresentationClock.estimateNow(commitEndNanos: commit, anchor: nil, display: display, offset: offset)
            }
        }

        private func record(_ tick: FrameTick) -> Bool { // perf-hot: 0.01ms frame-tick (held frames only)
            framesLeft -= 1
            // A synthesized (stalled) frame has no refresh interval and is not a vsync; it still counts.
            if let refresh = tick.refreshInterval, refresh > 0 {
                let anchor = PhaseAnchor(vsyncNanos: PresentationClock.nanos(tick.targetTimestamp),
                                         refreshNanos: PresentationClock.nanos(refresh), display: display)
                self.anchor = anchor
                resolvePending { commit in PresentationClock.estimate(commitEndNanos: commit, tick: anchor, offset: offset) }
            } else if framesLeft <= 0 {
                resolvePending { commit in
                    PresentationClock.estimateNow(commitEndNanos: commit, anchor: anchor, display: display, offset: offset)
                }
            }
            // A commit queued by a resolve callback waits for the next tick.
            if !pending.isEmpty { framesLeft = max(framesLeft, 1) }
            return framesLeft > 0
        }

        /// Resolves every queued commit; one queued meanwhile (by a callback) waits in the other buffer.
        private func resolvePending(_ estimate: (UInt64) -> PresentedEstimate) {
            guard !pending.isEmpty else { return }
            swap(&pending, &resolving)
            for commit in resolving { commit.resolve(estimate(commit.commitEndNanos)) }
            resolving.removeAll(keepingCapacity: true)
        }
    }
}

/// The presented-time estimate of one commit (``PresentationClock``).
public struct PresentedEstimate: Sendable, Hashable {
    /// Where the vsync phase of the estimate came from.
    public enum Basis: Sendable, Hashable {
        /// The first real tick of the window's link after the commit, within
        /// ``PresentationClock/holdFrames`` frames of it.
        case heldVsync
        /// An older or later real tick of the same display, extended by its refresh interval (drifts
        /// on a variable-refresh display).
        case extrapolated
        /// No usable tick (none yet, another display, or too old): the display's nominal refresh,
        /// half a frame to the next vsync.
        case nominal
    }

    /// The estimated presentation time, `CLOCK_UPTIME_RAW` nanoseconds.
    public let nanos: UInt64
    /// Where the vsync phase came from.
    public let basis: Basis
    /// The refresh interval used, in nanoseconds.
    public let refreshNanos: UInt64
    /// The display has a variable refresh rate (its minimum and maximum intervals differ): label the sample.
    public let isVariableRefresh: Bool

    /// An estimate of `nanos` from `basis`, on a display with `refreshNanos` refresh.
    public init(nanos: UInt64, basis: Basis, refreshNanos: UInt64, isVariableRefresh: Bool) {
        self.nanos = nanos
        self.basis = basis
        self.refreshNanos = refreshNanos
        self.isVariableRefresh = isVariableRefresh
    }
}
