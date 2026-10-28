import CmuxNextCompat
public import Foundation

/// The main-thread part of the next report: the active time
/// (``ActiveTimeLedger``) and what the watchdog's main-turn and input-queueing histograms counted
/// since the last queued report. The histograms (`MainTurnHistogram` in CmuxNextControl) count from
/// launch, so a report sends the difference from the read the last queued report ended at, as
/// Chrome's `HistogramSnapshotManager` sends each upload's `SnapshotDelta`
/// (base/metrics/histogram_snapshot_manager.cc): the server adds reports, so a count goes once.
///
/// ``take()`` reads without changing anything; ``commit(_:)`` advances the active time and the
/// baseline once that report is queued, so a report dropped before it is queued loses nothing.
/// ``saved()`` keeps what is not yet sent across a quit (``merge(_:)`` at the next launch).
///
/// ```swift
/// let taken = ledger.take()
/// let report = builder.build(context: context, watchdog: aggregate, metricKit: inputs, mainThread: taken.input)
/// // queue the body, then:
/// ledger.commit(taken)
/// ```
public final class MainThreadReportLedger: Sendable {
    /// One read of both histograms over their shared bucket edges, or a difference of two reads.
    public struct Histograms: Codable, Sendable, Equatable {
        /// The fine bucket edges in nanoseconds (`MainTurnHistogram.edgesNanos`).
        public var edgesNanos: [UInt64]
        /// The main-turn counts, one per bucket (`edgesNanos.count + 1`).
        public var turnCounts: [UInt64]
        /// The input-queueing counts, in the same buckets.
        public var inputQueueingCounts: [UInt64]

        /// Makes the value from its parts.
        public init(edgesNanos: [UInt64], turnCounts: [UInt64], inputQueueingCounts: [UInt64]) {
            self.edgesNanos = edgesNanos
            self.turnCounts = turnCounts
            self.inputQueueingCounts = inputQueueingCounts
        }

        /// Whether both histograms counted nothing.
        public var isEmpty: Bool { turnCounts.allSatisfy { $0 == 0 } && inputQueueingCounts.allSatisfy { $0 == 0 } }

        /// The counts since `baseline`, an earlier read over the same edges. A bucket below its
        /// baseline was zeroed since (`debug.hangs clear`), so all of its count is new; a baseline of
        /// another shape is ignored.
        func subtracting(_ baseline: Histograms?) -> Histograms {
            guard let baseline, matches(baseline) else { return self }
            return Histograms(edgesNanos: edgesNanos, turnCounts: Self.since(turnCounts, baseline.turnCounts),
                              inputQueueingCounts: Self.since(inputQueueingCounts, baseline.inputQueueingCounts))
        }

        /// These counts plus `other`'s; `other` of another shape is left out.
        func adding(_ other: Histograms?) -> Histograms {
            guard let other, matches(other) else { return self }
            return Histograms(edgesNanos: edgesNanos, turnCounts: Self.sum(turnCounts, other.turnCounts),
                              inputQueueingCounts: Self.sum(inputQueueingCounts, other.inputQueueingCounts))
        }

        private static func since(_ now: [UInt64], _ base: [UInt64]) -> [UInt64] {
            zip(now, base).map { now, base in now >= base ? now - base : now }
        }

        private static func sum(_ lhs: [UInt64], _ rhs: [UInt64]) -> [UInt64] {
            zip(lhs, rhs).map { lhs, rhs in
                let (total, overflow) = lhs.addingReportingOverflow(rhs)
                return overflow ? .max : total
            }
        }

        private func matches(_ other: Histograms) -> Bool {
            other.edgesNanos == edgesNanos && other.turnCounts.count == turnCounts.count
                && other.inputQueueingCounts.count == inputQueueingCounts.count
        }
    }

    /// What one launch leaves for the next: the active time and the histogram counts not yet sent.
    public struct Saved: Codable, Sendable, Equatable {
        /// Active nanoseconds not yet sent.
        public var activeNanos: UInt64
        /// The counts not yet sent; nil when the histograms were not read.
        public var histograms: Histograms?

        /// Makes the value from its parts.
        public init(activeNanos: UInt64, histograms: Histograms?) {
            self.activeNanos = activeNanos
            self.histograms = histograms
        }

        /// Whether there is nothing to keep.
        public var isEmpty: Bool { activeNanos < ActiveTimeLedger.nanosPerSecond && (histograms?.isEmpty ?? true) }
    }

    /// One ``take()``: the builder's input and what ``commit(_:)`` advances to.
    public struct Taken: Sendable, Equatable {
        /// What the report carries.
        public var input: HangReportBuilder.MainThreadInput
        /// The cumulative read the counts end at; the next baseline.
        var read: Histograms?

        /// Whether the report would say nothing new (no active second, no turn, no queued input).
        public var isEmpty: Bool {
            input.activeSeconds == 0 && input.turnCounts.allSatisfy { $0 == 0 } && input.inputQueueingCounts.allSatisfy { $0 == 0 }
        }
    }

    private struct State {
        var activeTime: ActiveTimeLedger
        /// The cumulative read the last queued report (or the last ``restart()``) ended at.
        var baseline: Histograms?
        /// Counts an earlier launch saved and no report sent yet.
        var carried: Histograms?

        func unsent(_ read: Histograms?) -> Histograms? {
            guard let read else { return carried }
            return read.subtracting(baseline).adding(carried)
        }
    }

    // Lock carve-out: activation notices and at most one input a second note here synchronously on
    // the main thread, and the report actor reads; an actor would add a Task and a hop per note.
    private let state: Mutex<State>
    private let uptimeNanos: @Sendable () -> UInt64
    private let read: @Sendable () -> Histograms?

    /// - Parameters:
    ///   - inactivityTimeoutNanos: How long without input ends an active span (Chrome's 5 minutes).
    ///   - uptimeNanos: The clock of every stamp (`CLOCK_UPTIME_RAW`, the clock of `NSEvent.timestamp`).
    ///   - histograms: Reads both cumulative histograms (allocates; called off the main thread when a
    ///     report is built, and once at a quit); nil when there are none.
    public init(inactivityTimeoutNanos: UInt64 = ActiveTimeLedger.defaultInactivityTimeoutNanos,
                uptimeNanos: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                histograms: @escaping @Sendable () -> Histograms?) {
        state = Mutex(State(activeTime: ActiveTimeLedger(inactivityTimeoutNanos: inactivityTimeoutNanos)))
        self.uptimeNanos = uptimeNanos
        read = histograms
    }

    // MARK: Notes (main thread)

    /// The app became active.
    public func didBecomeActive() {
        let now = uptimeNanos()
        state.withLock { $0.activeTime.didBecomeActive(atNanos: now) }
    }

    /// The app resigned active.
    public func didResignActive() {
        let now = uptimeNanos()
        state.withLock { $0.activeTime.didResignActive(atNanos: now) }
    }

    /// The person's input at `nanos` (the event's own uptime stamp).
    public func didReceiveUserInput(atNanos nanos: UInt64) {
        state.withLock { $0.activeTime.didReceiveUserInput(atNanos: nanos) }
    }

    /// Whether the app is active now.
    public var isActive: Bool { state.withLock { $0.activeTime.isActive } }

    // MARK: Reports

    /// What the next report would carry; changes nothing.
    public func take() -> Taken {
        let now = uptimeNanos()
        let current = read()
        return state.withLock { state in
            let unsent = state.unsent(current)
            let input = HangReportBuilder.MainThreadInput(
                activeSeconds: state.activeTime.seconds(atNanos: now), edgesNanos: unsent?.edgesNanos ?? [],
                turnCounts: unsent?.turnCounts ?? [], inputQueueingCounts: unsent?.inputQueueingCounts ?? [])
            return Taken(input: input, read: current)
        }
    }

    /// The report holding `taken` was queued: its seconds and counts leave the ledger.
    public func commit(_ taken: Taken) {
        let now = uptimeNanos()
        state.withLock { state in
            state.activeTime.commit(seconds: taken.input.activeSeconds, atNanos: now)
            if let read = taken.read { state.baseline = read }
            state.carried = nil
        }
    }

    /// Reports were turned on or off: nothing counted before now is sent.
    public func restart() {
        let now = uptimeNanos()
        let current = read()
        state.withLock { state in
            state.activeTime.discardCounted(atNanos: now)
            state.baseline = current
            state.carried = nil
        }
    }

    /// What is not yet sent, for the next launch.
    public func saved() -> Saved {
        let now = uptimeNanos()
        let current = read()
        return state.withLock { Saved(activeNanos: $0.activeTime.countedNanos(atNanos: now), histograms: $0.unsent(current)) }
    }

    /// Adds what an earlier launch saved.
    public func merge(_ saved: Saved) {
        state.withLock { state in
            state.activeTime.add(savedNanos: saved.activeNanos)
            if let histograms = saved.histograms {
                state.carried = state.carried.map { $0.adding(histograms) } ?? histograms
            }
        }
    }
}
