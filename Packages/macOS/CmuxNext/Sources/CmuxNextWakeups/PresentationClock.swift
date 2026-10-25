public import AppKit

/// When a main-thread commit reaches the glass: the presented end of an input's latency
/// (plans/cmux-next/chrome-parity/p04-input.md, section I, task 003).
///
/// cmux gets no presentation feedback for AppKit content, so the time is an estimate: the vsync
/// that picks up the commit (the first vsync at or after the commit's end), plus one render-server
/// frame, plus a per-OS constant (``PresentationOffset``, calibrated by the glass check, DC3).
///
/// Chrome: `gfx::PresentationFeedback` (`ui/gfx/presentation_feedback.h`) says whether a time is a
/// real vsync (`kVSync`); ``PresentedEstimate/Basis`` says the same of this estimate. The phase is
/// extended with `base::TimeTicks::SnappedToNextTick` (`base/time/time.h`) arithmetic, as
/// `viz::DelayBasedTimeSource` does, and the vsync comes from the display's one link
/// (`ui/display/mac/display_link_mac.h`): the clock never makes a link of its own. It subscribes a
/// ``FrameClient`` to the window's ``FrameScheduler`` (which subscribes to the display's clock) for
/// ``holdFrames`` frames after each tracked input, so a commit after an input reads the real
/// target timestamp, and an idle window keeps no link.
@MainActor
public final class PresentationClock {
    /// Frames the window's link stays subscribed after the last tracked input.
    public nonisolated static let holdFrames = 3

    /// The frame scheduler of a window (``FrameScheduler/forWindow(_:)``; a fake in tests).
    public typealias SchedulerForWindow = @MainActor (NSWindow) -> FrameScheduler
    /// The refresh range of a scheduler's display; nil when it has no screen.
    public typealias DisplayForScheduler = @MainActor (FrameScheduler) -> PresentationDisplay?

    private let offset: PresentationOffset
    private let schedulerForWindow: SchedulerForWindow
    private let displayForScheduler: DisplayForScheduler
    private var holds: [ObjectIdentifier: Hold] = [:]

    /// - Parameters:
    ///   - offset: The per-OS constant added to every estimate.
    ///   - scheduler: The scheduler that holds a window's link.
    ///   - display: The refresh range of a scheduler's display.
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

    /// The hold of `scheduler`, made on its first input (one allocation per window, not per input).
    private func hold(for scheduler: FrameScheduler) -> Hold {
        let key = ObjectIdentifier(scheduler)
        if let hold = holds[key], hold.scheduler === scheduler { return hold }
        holds = holds.filter { $0.value.scheduler != nil }
        let hold = Hold(scheduler: scheduler)
        holds[key] = hold
        return hold
    }

    // MARK: Estimates

    /// The estimated presentation time of a commit that ended at `commitEndNanos` in `window`.
    public func presented(commitEndNanos: UInt64, window: NSWindow) -> PresentedEstimate {
        presented(commitEndNanos: commitEndNanos, on: schedulerForWindow(window))
    }

    /// The estimated presentation time of a commit that ended at `commitEndNanos`
    /// (`CLOCK_UPTIME_RAW`, as `CommitBoundary.Commit.commitEndNanos`) on `scheduler`'s display.
    ///
    /// Starts no link and subscribes no client: with no recent tick it extends the last known
    /// phase, and with no tick at all it uses the display's nominal refresh.
    public func presented(commitEndNanos: UInt64, on scheduler: FrameScheduler) -> PresentedEstimate {
        let display = displayForScheduler(scheduler)
        let isVariableRefresh = display?.isVariableRefresh ?? false
        let key = ObjectIdentifier(scheduler)
        if let hold = holds[key], hold.scheduler === scheduler, let anchor = hold.vsyncNanos, hold.refreshNanos > 0 {
            let interval = hold.refreshNanos
            let vsync = Self.vsync(atOrAfter: commitEndNanos, anchor: anchor, interval: interval)
            let drift = vsync > anchor ? vsync - anchor : anchor - vsync
            let basis: PresentedEstimate.Basis = drift <= UInt64(Self.holdFrames) * interval ? .heldVsync : .extrapolated
            return PresentedEstimate(nanos: offset.applied(to: vsync + interval), basis: basis, refreshNanos: interval,
                                     isVariableRefresh: isVariableRefresh)
        }
        // No phase known: on average the next vsync is half a frame away.
        let interval = Self.nanos(display?.minimumRefreshInterval ?? Self.fallbackRefreshInterval)
        return PresentedEstimate(nanos: offset.applied(to: commitEndNanos + interval / 2 + interval), basis: .nominal,
                                 refreshNanos: interval, isVariableRefresh: isVariableRefresh)
    }

    /// The refresh interval used with no display (a 60 Hz panel).
    nonisolated static let fallbackRefreshInterval: Double = 1.0 / 60.0

    /// The first vsync at or after `time`, on the grid `anchor + k * interval`
    /// (`base::TimeTicks::SnappedToNextTick`).
    nonisolated static func vsync(atOrAfter time: UInt64, anchor: UInt64, interval: UInt64) -> UInt64 {
        if time <= anchor { return anchor - (anchor - time) / interval * interval }
        return anchor + (time - anchor + interval - 1) / interval * interval
    }

    /// Seconds (`CACurrentMediaTime` base, which is `CLOCK_UPTIME_RAW`) as nanoseconds.
    nonisolated static func nanos(_ seconds: Double) -> UInt64 {
        seconds > 0 ? UInt64((seconds * 1e9).rounded()) : 0
    }

    /// The link subscription of one window: a non-animation client that records each real tick's
    /// target timestamp and goes idle after the hold's last frame.
    @MainActor
    private final class Hold {
        weak var scheduler: FrameScheduler?
        var framesLeft = 0
        /// The target timestamp of the last real tick (a vsync), in nanoseconds; nil before one.
        var vsyncNanos: UInt64?
        var refreshNanos: UInt64 = 0
        /// Weak both ways: a closed window's scheduler goes with its window, and the hold goes with the clock.
        private(set) lazy var client: FrameClient = FrameClient(owner: "PresentationClock.hold", isAnimation: false,
                                                   scheduler: { [weak self] in self?.scheduler ?? .app }) { [weak self] tick in
            self?.record(tick) ?? false
        }

        init(scheduler: FrameScheduler) {
            self.scheduler = scheduler
        }

        private func record(_ tick: FrameTick) -> Bool { // perf-hot: 0.01ms frame-tick (held frames only)
            // A synthesized (stalled) frame has no refresh interval and is not a vsync; it still ends the hold.
            // The scheduler's refresh interval is the link's targetTimestamp - timestamp, so this
            // sum is the link's targetTimestamp (FrameTick.targetTimestamp once p03-rendering-012 adds it).
            if let refresh = tick.refreshInterval, refresh > 0 {
                let interval = PresentationClock.nanos(refresh)
                refreshNanos = interval
                vsyncNanos = PresentationClock.nanos(tick.timestamp) + interval
            }
            framesLeft -= 1
            return framesLeft > 0
        }
    }
}

/// The presented-time estimate of one commit (``PresentationClock``).
public struct PresentedEstimate: Sendable, Hashable {
    /// Where the vsync phase of the estimate came from.
    public enum Basis: Sendable, Hashable {
        /// A tick of the window's link within ``PresentationClock/holdFrames`` frames of the commit.
        case heldVsync
        /// An older tick's phase, extended by its refresh interval (drifts on a variable-refresh display).
        case extrapolated
        /// No tick seen on this window: the display's nominal refresh, half a frame to the next vsync.
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

    public init(nanos: UInt64, basis: Basis, refreshNanos: UInt64, isVariableRefresh: Bool) {
        self.nanos = nanos
        self.basis = basis
        self.refreshNanos = refreshNanos
        self.isVariableRefresh = isVariableRefresh
    }
}
