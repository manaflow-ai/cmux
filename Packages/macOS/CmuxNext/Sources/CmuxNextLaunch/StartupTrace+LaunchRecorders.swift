import CmuxNextCompat
public import CmuxNextWakeups

extension StartupTrace {
    /// The launch's two recorders behind the producers' single hooks (``BackgroundWork``'s `onRan`, the watchdog's
    /// main-turn sink): the developer trace (`CMUX_TRACE_STARTUP`, ``StartupTrace``) and the Nightly slow-launch ring
    /// (``SlowLaunchRing``, p08-startup-111). Each hook calls both, and each recorder ignores records once it stopped
    /// (one relaxed load), so freeing the ring at `startup_complete` never stops the trace's lane records and closing
    /// the trace never stops the ring's. A hook comes off only when every recorder stopped (``whenAllStopped(_:)``).
    ///
    /// Chrome's trace log fans one set of category-enabled flags out to every session the same way: a producer checks
    /// one flag, each session keeps its own buffer and stops on its own (base/trace_event/trace_log.cc).
    ///
    /// ```swift
    /// let recorders = StartupTrace.LaunchRecorders(trace: startupTrace, ring: slowLaunchRing)
    /// let work = BackgroundWork(hangs: hangWatch, onRan: recorders.laneJobSink)
    /// recorders.whenAllStopped { work.stopReportingRuns() }
    /// ```
    public struct LaunchRecorders: Sendable {
        /// The developer trace, when `CMUX_TRACE_STARTUP` asked for one.
        public let trace: StartupTrace?
        /// The slow-launch ring, when hang reports are on.
        public let ring: SlowLaunchRing?

        /// The recorders of this launch; none when both are nil (the usual launch): every hook is then nil.
        public init(trace: StartupTrace?, ring: SlowLaunchRing?) {
            self.trace = trace
            self.ring = ring
        }

        /// Whether the launch records nothing.
        public var isEmpty: Bool { trace == nil && ring == nil }

        /// The recorders' clock now (`CLOCK_UPTIME_RAW` nanoseconds), a task's start for ``task(_:start:)``; nil, with
        /// no clock read, when there is no recorder.
        public var uptimeNanos: UInt64? { trace?.uptimeNanos ?? ring?.uptimeNanos }

        /// A startup task that ran from `start` to now on the calling thread, in every recorder.
        public func task(_ name: StaticString, start: UInt64) {
            trace?.task(name, start: start)
            ring?.task(name, start: start)
        }

        /// ``BackgroundWork``'s `onRan` for every recorder; nil when there is none.
        public var laneJobSink: (@Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void)? {
            let sinks = [trace?.laneJobSink, ring?.laneJobSink].compactMap { $0 }
            guard !sinks.isEmpty else { return nil }
            return { lane, priority, start, end in
                for sink in sinks { sink(lane, priority, start, end) }
            }
        }

        /// The watchdog's main-turn sink for every recorder (turns over ``StartupTrace/mainTurnThresholdNanos``);
        /// nil when there is none.
        public var mainTurnSink: (@Sendable (UInt64, UInt64) -> Void)? {
            guard !isEmpty else { return nil }
            let trace = trace, ring = ring
            return { start, end in
                trace?.mainTurn(start: start, end: end)
                ring?.mainTurn(start: start, end: end)
            }
        }

        /// Runs `action` once, when every recorder stopped (the trace closed and the ring freed), on the thread of
        /// the last stop; at once when there is none. `action` must return at once.
        public func whenAllStopped(_ action: @escaping @Sendable () -> Void) {
            let left = RecorderStopCountdown(count: (trace == nil ? 0 : 1) + (ring == nil ? 0 : 1), action: action)
            trace?.whenClosed { left.stopped() }
            ring?.whenFreed { left.stopped() }
        }
    }
}

/// Runs its action when the last of `count` recorders stopped (at once for 0): one atomic decrement per stop.
private final class RecorderStopCountdown: Sendable {
    private let left: Atomic<Int>
    private let action: @Sendable () -> Void

    init(count: Int, action: @escaping @Sendable () -> Void) {
        left = Atomic(count)
        self.action = action
        if count == 0 { action() }
    }

    func stopped() {
        if left.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 { action() }
    }
}
