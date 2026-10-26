import CmuxNextCompat

/// Counts what each observer owner does (plans/cmux-next/chrome-parity/p06-scheduler.md, section C):
/// how many of its observations are armed now, how often they were evaluated and applied, how many
/// re-reads a show cost and how long they took, and how many SwiftUI hosting bodies it evaluated,
/// visible and hidden. `debug.observations` reads ``snapshot()``; a bench reads it before and after
/// one change and diffs the counts.
///
/// The recording path takes no lock: an observer interns its owner once, when it is built
/// (``owner(_:)`` takes the ledger's lock), and keeps the returned ``Owner``; each event after that
/// is one relaxed atomic add on that handle. Chrome counts the same way: a histogram sample is a
/// lock-free atomic accumulate (`base/metrics/histogram_samples.h`, `AtomicSingleSample`), and only
/// the reader walks the registry (`base/metrics/statistics_recorder.cc`).
///
/// Owner names name a kind of observer ("SidebarRow.status", "TasksHostView"), never one instance:
/// interned owners stay for the ledger's life.
///
/// ```swift
/// let owner = ledger.owner("SidebarRow.status")   // when the feed is built
/// owner.armed()                                    // the row became visible and tracks
/// owner.evaluated(); owner.applied()               // one change re-read and applied
/// owner.disarmed()                                 // the row was hidden
/// ```
public final class ObservationLedger: Sendable {
    /// One owner's counters. Every method is one relaxed atomic operation, safe on any thread.
    public final class Owner: Sendable {
        /// The name ``ObservationLedger/owner(_:)`` interned.
        public let name: String
        private let armedNow = Atomic<Int>(0)
        private let arms = Atomic<UInt64>(0)
        private let evaluations = Atomic<UInt64>(0)
        private let applies = Atomic<UInt64>(0)
        private let showRereads = Atomic<UInt64>(0)
        private let showRereadNanos = Atomic<UInt64>(0)
        private let showRereadMaxNanos = Atomic<UInt64>(0)
        private let bodies = Atomic<UInt64>(0)
        private let hiddenBodies = Atomic<UInt64>(0)

        init(name: String) {
            self.name = name
        }

        /// One observation of this owner started tracking (it became visible, or a service started).
        public func armed() {
            armedNow.add(1, ordering: .relaxed)
            arms.add(1, ordering: .relaxed)
        }

        /// One observation of this owner stopped tracking (hidden, cancelled or released).
        public func disarmed() {
            armedNow.subtract(1, ordering: .relaxed)
        }

        /// One observation ran its read after a change.
        public func evaluated() {
            evaluations.add(1, ordering: .relaxed)
        }

        /// One observation applied a new value (after its Equatable dedupe).
        public func applied() {
            applies.add(1, ordering: .relaxed)
        }

        /// One observation re-read its value because its node was shown, in `nanos` (monotonic).
        public func showReread(nanos: UInt64) {
            showRereads.add(1, ordering: .relaxed)
            showRereadNanos.add(nanos, ordering: .relaxed)
            var seen = showRereadMaxNanos.load(ordering: .relaxed)
            while nanos > seen {
                let result = showRereadMaxNanos.weakCompareExchange(expected: seen, desired: nanos, ordering: .relaxed)
                if result.exchanged { break }
                seen = result.original
            }
        }

        /// One SwiftUI hosting view body of this owner was evaluated; `hidden` when its node was
        /// hidden at the time (the budget is 0 hidden bodies).
        public func bodyEvaluated(hidden: Bool) {
            bodies.add(1, ordering: .relaxed)
            if hidden { hiddenBodies.add(1, ordering: .relaxed) }
        }

        var entry: Entry {
            Entry(owner: name,
                  armed: armedNow.load(ordering: .relaxed),
                  arms: arms.load(ordering: .relaxed),
                  evaluations: evaluations.load(ordering: .relaxed),
                  applies: applies.load(ordering: .relaxed),
                  showRereads: showRereads.load(ordering: .relaxed),
                  showRereadNanos: showRereadNanos.load(ordering: .relaxed),
                  showRereadMaxNanos: showRereadMaxNanos.load(ordering: .relaxed),
                  bodyEvaluations: bodies.load(ordering: .relaxed),
                  hiddenBodyEvaluations: hiddenBodies.load(ordering: .relaxed))
        }

        /// Zeroes the counts; ``Entry/armed`` is state, not a count, and stays.
        func reset() {
            arms.store(0, ordering: .relaxed)
            evaluations.store(0, ordering: .relaxed)
            applies.store(0, ordering: .relaxed)
            showRereads.store(0, ordering: .relaxed)
            showRereadNanos.store(0, ordering: .relaxed)
            showRereadMaxNanos.store(0, ordering: .relaxed)
            bodies.store(0, ordering: .relaxed)
            hiddenBodies.store(0, ordering: .relaxed)
        }
    }

    /// One owner's counts at ``snapshot()`` time, since launch or the last ``reset()``.
    public struct Entry: Sendable, Equatable {
        public var owner: String
        /// Observations tracking now (not reset).
        public var armed: Int
        /// Times an observation started tracking.
        public var arms: UInt64
        /// Reads after a change.
        public var evaluations: UInt64
        /// Applies of a new value.
        public var applies: UInt64
        /// Re-reads in a show.
        public var showRereads: UInt64
        /// Their total time, in nanoseconds.
        public var showRereadNanos: UInt64
        /// The longest one, in nanoseconds.
        public var showRereadMaxNanos: UInt64
        /// SwiftUI hosting body evaluations.
        public var bodyEvaluations: UInt64
        /// The part of ``bodyEvaluations`` that ran while the node was hidden.
        public var hiddenBodyEvaluations: UInt64
    }

    private let owners = Mutex<[String: Owner]>([:])

    public init() {}

    /// The counters for `name`, interned on first use. Takes the ledger's lock: call it when the
    /// observer or its factory is built and keep the handle, never per change.
    public func owner(_ name: String) -> Owner {
        owners.withLock { owners in
            if let owner = owners[name] { return owner }
            let owner = Owner(name: name)
            owners[name] = owner
            return owner
        }
    }

    /// Every owner, the most evaluated first (ties by name).
    public func snapshot() -> [Entry] {
        owners.withLock { Array($0.values) }
            .map(\.entry)
            .sorted { ($1.evaluations, $0.owner) < ($0.evaluations, $1.owner) }
    }

    /// Zeroes every owner's counts. Armed observations stay armed and are still reported.
    public func reset() {
        for owner in owners.withLock({ Array($0.values) }) { owner.reset() }
    }
}
