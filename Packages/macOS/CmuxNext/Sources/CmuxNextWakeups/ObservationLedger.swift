import CmuxNextCompat

/// Counts what each observer owner does (plans/cmux-next/chrome-parity/p06-scheduler.md, section C):
/// how many of its observations are armed now, how often they were evaluated and applied, how many
/// re-reads a show cost and how long they took, and how many SwiftUI hosting bodies it evaluated,
/// visible and hidden. `debug.observations` reads ``snapshot(matching:resetting:)``; a bench reads it before and after
/// one change and diffs the counts.
///
/// The recording path takes no lock: each owner name is interned once (``owner(_:)`` takes the
/// ledger's lock; observers made per node on main go through ``MainWorkScheduler/observationOwner(_:)``,
/// which caches the handle, so only a name's first instance takes it), and each event after that is
/// one relaxed atomic add on the returned ``Owner``. Chrome counts the same way: a histogram sample is a
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

        /// One observation ran its read after a change and, when `applied`, applied a new value.
        public func evaluated(applied: Bool) {
            evaluations.add(1, ordering: .relaxed)
            if applied { applies.add(1, ordering: .relaxed) }
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
        /// hidden at the time (the budget is 0 hidden bodies). A tab page's `VisibilityGatedHostingView`
        /// (CmuxNextDesign) records it under `Hosting.<page>`; a gated page that runs a hidden body opted out.
        public func bodyEvaluated(hidden: Bool) {
            bodies.add(1, ordering: .relaxed)
            if hidden { hiddenBodies.add(1, ordering: .relaxed) }
        }

        /// The counts now; with `resetting`, each count is read and zeroed in one atomic exchange, so an event
        /// recorded while the reader runs is in this entry or the next one, never lost (Chrome takes a delta the
        /// same way: `HistogramSamples::Extract`, base/metrics/histogram_samples.cc). ``Entry/armed`` is state,
        /// not a count: it is only loaded.
        func entry(resetting: Bool) -> Entry {
            func read(_ counter: borrowing Atomic<UInt64>) -> UInt64 {
                resetting ? counter.exchange(0, ordering: .relaxed) : counter.load(ordering: .relaxed)
            }
            return Entry(owner: name,
                         armed: armedNow.load(ordering: .relaxed),
                         arms: read(arms),
                         evaluations: read(evaluations),
                         applies: read(applies),
                         showRereads: read(showRereads),
                         showRereadNanos: read(showRereadNanos),
                         showRereadMaxNanos: read(showRereadMaxNanos),
                         bodyEvaluations: read(bodies),
                         hiddenBodyEvaluations: read(hiddenBodies))
        }
    }

    /// One owner's counts at ``snapshot(matching:resetting:)`` time, since launch or its last reset.
    public struct Entry: Sendable, Equatable {
        /// The observations' owner.
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

        /// An entry with every count given.
        public init(owner: String, armed: Int, arms: UInt64, evaluations: UInt64, applies: UInt64, showRereads: UInt64,
                    showRereadNanos: UInt64, showRereadMaxNanos: UInt64, bodyEvaluations: UInt64, hiddenBodyEvaluations: UInt64) {
            self.owner = owner
            self.armed = armed
            self.arms = arms
            self.evaluations = evaluations
            self.applies = applies
            self.showRereads = showRereads
            self.showRereadNanos = showRereadNanos
            self.showRereadMaxNanos = showRereadMaxNanos
            self.bodyEvaluations = bodyEvaluations
            self.hiddenBodyEvaluations = hiddenBodyEvaluations
        }
    }

    private let owners = Mutex<[String: Owner]>([:])

    /// A ledger with no owner counted.
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

    /// Every owner whose name starts with `prefix`, the most evaluated first (ties by name). With `resetting`,
    /// the counts of exactly those owners are zeroed as they are read; owners outside `prefix` keep theirs.
    public func snapshot(matching prefix: String = "", resetting: Bool = false) -> [Entry] {
        owners.withLock { owners in owners.values.filter { $0.name.hasPrefix(prefix) } }
            .map { $0.entry(resetting: resetting) }
            .sorted { ($1.evaluations, $0.owner) < ($0.evaluations, $1.owner) }
    }
}
