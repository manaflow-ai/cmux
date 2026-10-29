import CmuxNextCompat

/// What the arm census (``ArmCensus``) records: the kind of an armed object.
public enum ArmCensusKind: String, Sendable, CaseIterable {
    /// A ``DemandTimer`` deadline.
    case timer
    /// A deadline on the main thread's wake-up queue: a ``MainDeadline``, or a one-shot
    /// ``AlignedWakeups/schedule(owner:after:placement:file:line:_:)``.
    case mainDeadline = "main_deadline"
    /// A file-system watch: ``FolderChanges``, or a DispatchSource or FSEvents watch with an ``ArmCensusWatch``.
    case watcher
    /// A system notification observer: an ``AppEvents`` channel on a system center (NSWorkspace, distributed).
    case observer
}

#if DEBUG || CMUX_BENCH_HOOKS
/// One watcher's record in its ledger's ``ArmCensus`` (startup-queue.py arms), for a watch made outside
/// the timer primitives: a DispatchSource or FSEvents watch, a system observer. The owner calls ``armed()`` each time it
/// arms the watch (a re-opened file counts as another arm before the first fire) and ``fired()`` on each event, the
/// process wakeup the watch costs; the census keeps the first arm made while it records and the first fire, whenever
/// it comes. In Release it is empty and each call is a no-op the compiler removes.
///
/// It is a value with no lock, so an owner whose state is all `let` (a `Sendable` class) keeps one: concurrent calls
/// agree through one atomic word. Chrome keeps the same facts per delayed task (`posted_from` and the queue time,
/// base/pending_task.h).
///
/// ```swift
/// private let census: ArmCensusWatch
/// init(..., ledger: WakeupLedger = .shared, file: StaticString = #fileID, line: UInt = #line) {
///     census = ArmCensusWatch(ledger: ledger, .watcher, owner: "ConfigFileWatcher", file: file, line: line)
/// }
/// func arm() { ...; census.armed() }
/// func eventHandler() { census.fired(); ... }
/// ```
public struct ArmCensusWatch: Sendable {
    private let record: Record

    /// - Parameters:
    ///   - ledger: Whose census records it (the one the owner counts its wakes in).
    ///   - kind: What it is.
    ///   - owner: The name in the census.
    ///   - file: The line that made the owner, named by the census (pass the owner's own `#fileID` default).
    ///   - line: See `file`.
    public init(ledger: WakeupLedger = .shared, _ kind: ArmCensusKind, owner: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) {
        record = Record(census: ledger.armCensus, kind: kind, owner: owner(), site: ArmCensus.Site(file: file, line: line))
    }

    /// The watch is armed: its first arm while the census records is its record; a later one before its first fire
    /// is counted.
    public func armed() {
        record.armed()
    }

    /// The watch woke the process: its first fire ends its record.
    public func fired() {
        record.fired()
    }

    /// The shared state of the copies of one watch.
    private final class Record: Sendable {
        /// ``state`` before the first arm.
        static let unarmed = -1
        /// ``state`` while an arm takes its census record.
        static let claiming = -2
        /// ``state`` after the first fire (or a census that could not keep it): nothing more is recorded.
        static let done = -3

        let census: ArmCensus
        let kind: ArmCensusKind
        let owner: String
        let site: ArmCensus.Site
        /// The census record's index once armed, else one of the states above.
        let state = Atomic<Int>(Record.unarmed)

        init(census: ArmCensus, kind: ArmCensusKind, owner: String, site: ArmCensus.Site) {
            self.census = census
            self.kind = kind
            self.owner = owner
            self.site = site
        }

        func armed() {
            let current = state.load(ordering: .acquiring)
            if current >= 0 { return census.rearmed(ArmCensus.Slot(index: current)) }
            guard current == Self.unarmed, census.isRecording,
                  state.compareExchange(expected: Self.unarmed, desired: Self.claiming, ordering: .acquiringAndReleasing).exchanged
            else { return }
            guard let slot = census.armed(kind, owner: owner, site: site) else {
                // Closed or full: nothing of this watch is recorded (a fire meanwhile already set done).
                state.compareExchange(expected: Self.claiming, desired: Self.done, ordering: .acquiringAndReleasing)
                return
            }
            // A fire while the record was taken set done: that fire is this watch's first.
            if !state.compareExchange(expected: Self.claiming, desired: slot.index, ordering: .acquiringAndReleasing).exchanged {
                census.fired(slot)
            }
        }

        func fired() {
            let original = state.exchange(Self.done, ordering: .acquiringAndReleasing)
            if original >= 0 { census.fired(ArmCensus.Slot(index: original)) }
        }
    }
}
#else
/// Release: the arm census is not built, and each call is a no-op (see the Debug and bench declaration).
public struct ArmCensusWatch: Sendable {
    @inlinable
    /// Builds nothing in Release.
    public init(ledger: WakeupLedger = .shared, _ kind: ArmCensusKind, owner: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) {}

    @inlinable
    /// Does nothing in Release.
    public func armed() {}

    @inlinable
    /// Does nothing in Release.
    public func fired() {}
}
#endif
