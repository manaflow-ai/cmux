public import CmuxNextWakeups
import Foundation
import Observation

/// Read by every row mapping of `SidebarRowFeed` under its observation;
/// writing it fires (and so removes) that observation.
@Observable
fileprivate final class SidebarRowWatchCancel {
    var epoch: UInt64 = 0
}

/// Row content observed one workspace at a time, so a status change of one
/// workspace (agent status, OSC 7501, title, unread, progress, favicon) maps
/// that one row again and never re-runs the structural sidebar pass.
///
/// The structural pass (an `ObservationStream` over order, groups, pins,
/// membership and machines) names each listed workspace with `row(_:make:)`:
/// it gets the last mapped row (or a stub for a new one) and reads nothing
/// observable, so it does not observe any row's status. After the pass,
/// outside its tracking, `fill` maps the new rows under their own
/// observation. A known row is already current: anything it read would have
/// marked it dirty. Only when the pass's by-value inputs change (`beginPass`)
/// is every row mapped and observed again. A change a row read marks it
/// dirty; one flush (per display frame in the app) maps the dirty rows again (each
/// observation fires once and is armed again, so none piles up) and hands
/// the changed ones to `onChange`.
///
/// Each row has one live observation at most: before a row is observed
/// again while its observation is still armed (the inputs changed), and
/// when a row is forgotten, the feed fires that observation through the
/// row's `Cancel` signal, so the registrar drops it, and the stale
/// callback is ignored by its generation. Observation tracking has no
/// cancel call; without this every inputs change left one registration per
/// unchanged row behind.
///
/// Each dirty row keeps the cause of the change that marked it, and each
/// cause has its own flushes (``init(cause:rowsPerBudgetedFlush:schedule:)``),
/// which map only the rows of that cause, in the order they were marked: a
/// person's row change neither waits behind nor pays for the rows automation
/// marked. A program or automation flush maps a bounded slice of rows, so a
/// budgeted queue spreads a burst of them over frames.
@MainActor
public final class SidebarRowFeed {
    /// Maps one row from its store; runs on the main actor (the feed and its callers are main-actor).
    public typealias Make = () -> SidebarWorkspace

    private final class Entry {
        var make: Make
        /// The last mapped row; each write moves `revision`.
        var row: SidebarWorkspace { didSet { revision &+= 1 } }
        /// Moves with every write of `row`.
        var revision: UInt64 = 0
        /// The `revision` of the row the last pass got from `row(_:machine:make:)` (`fill` writes the row only
        /// when it moved since); `.max` for a stub, which `fill` always writes.
        var namedRevision: UInt64 = .max
        /// The row's mapping has an observation armed.
        var armed = false
        /// The armed observation's generation; a callback of an older one is stale.
        var generation: UInt64 = 0
        let cancel = SidebarRowWatchCancel()
        /// The pass that last named the row.
        var pass: UInt64

        init(make: @escaping Make, row: SidebarWorkspace, pass: UInt64) {
            self.make = make
            self.row = row
            self.pass = pass
        }
    }

    private var entries: [WorkspaceID: Entry] = [:]
    /// The dirty rows, each with the cause of the change that marked it.
    private var dirty: [WorkspaceID: ObservationCause] = [:]
    /// Per cause (index `rawValue`): its dirty rows in marking order, and its scheduled flushes.
    private var lanes = [SidebarRowLane](repeating: SidebarRowLane(), count: ObservationCause.allCases.count)
    /// The rows one program or automation flush maps (person and frontend flushes map all of theirs).
    private let rowsPerBudgetedFlush: Int
    private var pass: UInt64 = 0
    /// The by-value inputs of the last pass, and whether a pass since the last `fill` changed them.
    private var inputs: AnyHashable?
    private var inputsChanged = false
    /// Rows mapped again since the last structural pass (the next `fill` maps only new rows).
    private var named: [WorkspaceID] = []
    /// Changed rows, at most once per flush.
    public var onChange: (([SidebarWorkspace]) -> Void)?
    /// Runs one flush later. The app hands the display frame (`FrameBatcher`): the row patches of
    /// a frame then land in that frame's display-link callback, beside the scroll's own update, so
    /// the frame has one commit (a main-actor task ran them between frames, a second commit that
    /// delayed the next frame's scroll update: scroll hitches with ticking rows, perf round 2).
    public typealias Schedule = (@escaping @MainActor @Sendable () -> Void) -> Void
    /// Runs one flush later, with the cause of the change that scheduled it (the app's budgeted
    /// queue runs a person or frontend flush unbudgeted: ``FrameBatchQueue/enqueue(cause:_:)``).
    public typealias CausedSchedule = @MainActor (ObservationCause, @escaping @MainActor @Sendable () -> Void) -> Void
    private let schedule: CausedSchedule
    /// The cause of the change being made now (the app's ``ObservationCauses/currentCause``).
    private let cause: @MainActor () -> ObservationCause
    /// `debug.observations`' counts of the rows: armed now, re-reads after a change and the ones that changed the row.
    private let observations: ObservationLedger.Owner?

    /// `schedule` defaults to the next main-actor turn. Every flush is ``ObservationCause/program``
    /// and maps every dirty row: one flush per turn. `observations` gets the feed's counts (the app's ledger).
    public convenience init(schedule: Schedule? = nil, observations: ObservationLedger.Owner? = nil) {
        // task-owner: the feed; one flush per main-actor turn after the store's batch applies
        let plain = schedule ?? { work in Task { @MainActor in work() } }
        self.init(cause: { .program }, rowsPerBudgetedFlush: .max, schedule: { _, work in plain(work) },
                  observations: observations)
    }

    /// A feed whose flushes carry their change's cause.
    ///
    /// - Parameters:
    ///   - cause: The cause of the change being made now, read when a change marks a row (in the
    ///     change's own turn).
    ///   - rowsPerBudgetedFlush: The rows one program or automation flush maps; each further slice
    ///     is a flush of its own, so a budgeted queue runs as many as fit a frame.
    ///   - schedule: Runs one flush later, with its cause.
    ///   - observations: The feed's owner in the app's ``ObservationLedger`` (`debug.observations`).
    public init(cause: @escaping @MainActor () -> ObservationCause, rowsPerBudgetedFlush: Int = 16,
                schedule: @escaping CausedSchedule, observations: ObservationLedger.Owner? = nil) {
        self.cause = cause
        self.rowsPerBudgetedFlush = max(1, rowsPerBudgetedFlush)
        self.schedule = schedule
        self.observations = observations
    }

    /// Starts a structural pass (call first in the pass's tracked closure).
    /// `inputs` are the values the pass hands every row's mapping by value
    /// (the muted set, the New Tab pages, whether unread shows): when they
    /// change, `fill` maps and observes every row again. Everything else a
    /// mapping needs it must read itself, so its own observation covers it.
    public func beginPass(inputs: AnyHashable) {
        pass &+= 1
        named.removeAll(keepingCapacity: true)
        if inputs != self.inputs { inputsChanged = true }
        self.inputs = inputs
    }

    /// Forgets every row and stops reporting (the window closed).
    public func reset() {
        onChange = nil
        for entry in entries.values { disarm(entry) }
        entries.removeAll()
        dirty.removeAll()
        for index in lanes.indices { lanes[index].dropRows() }
    }

    /// The row of `id` for the structural pass: the last mapped row, or a
    /// stub until `fill` maps it. `make` maps it from its store; it runs
    /// later, outside the pass's tracking.
    public func row(_ id: WorkspaceID, machine: MachineID, make: @escaping Make) -> SidebarWorkspace {
        named.append(id)
        if let entry = entries[id] {
            entry.make = make
            entry.pass = pass
            entry.namedRevision = entry.revision
            return entry.row
        }
        let stub = SidebarWorkspace(id: id, machineID: machine, title: "")
        entries[id] = Entry(make: make, row: stub, pass: pass)
        return stub
    }

    /// `sections` with every row the last pass named filled in: a new row
    /// mapped under its own observation, a known one as last mapped (all of
    /// them again when the pass's inputs changed). Forgets rows the pass did
    /// not name. Each row keeps its row state from `sections`. Call outside
    /// any observation tracking.
    ///
    /// Writes only the rows that differ from what the pass got (new rows, rows mapped again here or by a flush
    /// since): a reorder writes none, so its cost does not grow with the sidebar (a rewrite of every row was
    /// most of a reorder's main-thread time at 400 workspaces, and typing in a terminal waited on it:
    /// sidebar-churn-typing.py).
    public func fill(_ sections: [SidebarSection]) -> [SidebarSection] {
        SidebarPerfCounters.add(.rebuilds)
        return SidebarPerfCounters.timed { fillNow(sections) }
    }

    private func fillNow(_ sections: [SidebarSection]) -> [SidebarSection] {
        for (id, entry) in entries where entry.pass != pass {
            disarm(entry)
            entries[id] = nil
        }
        var rows: [SidebarWorkspace] = []
        let remap = inputsChanged
        inputsChanged = false
        for id in named {
            guard let entry = entries[id] else { continue }
            // A row whose content changed since its last map (dirty) keeps that row here: the scheduled flush maps it
            // and sends it as a patch. Mapped here, a tick's status would ride this pass as a structural set (hitch17:
            // a sidebar reload and an anchored offset shift every 1-2 s under 50 ticking terminals).
            if remap || (!entry.armed && dirty[id] == nil) { entry.row = arm(id, entry) }
            // The pass holds this row already, unless it was a stub or was mapped again since.
            if entry.revision != entry.namedRevision { rows.append(entry.row) }
            entry.namedRevision = entry.revision
        }
        if remap, !dirty.isEmpty { for id in named { dirty[id] = nil } }
        return SidebarRowIndex.patching(rows, in: sections)
    }

    /// Maps `entry` under an observation that marks it dirty on its next
    /// change; an observation still armed is removed first (one per row).
    private func arm(_ id: WorkspaceID, _ entry: Entry) -> SidebarWorkspace {
        disarm(entry)
        entry.armed = true
        observations?.armed()
        let generation = entry.generation
        let cancel = entry.cancel
        return withObservationTracking {
            _ = cancel.epoch
            return entry.make()
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { // main-proof: checked on the line above
                    guard let self else { return }
                    self.markDirty(id, generation: generation, cause: self.cause())
                }
            } else {
                // An off-main write is no request's: no cause scope covers it.
                Task { @MainActor [weak self] in self?.markDirty(id, generation: generation, cause: .program) }
            }
        }
    }

    /// Removes `entry`'s armed observation: the write fires it (the registrar
    /// drops it) and the new generation makes its callback a no-op.
    private func disarm(_ entry: Entry) {
        entry.generation &+= 1
        guard entry.armed else { return }
        entry.armed = false
        observations?.disarmed()
        entry.cancel.epoch &+= 1
    }

    private func markDirty(_ id: WorkspaceID, generation: UInt64, cause: ObservationCause) {
        guard let entry = entries[id], entry.generation == generation else { return }
        entry.armed = false
        observations?.disarmed()  // the observation fired, and so is gone
        if let marked = dirty[id], marked >= cause { return }
        dirty[id] = cause
        guard lanes[cause.rawValue].add(id, rowsPerFlush: rowsPerFlush(cause)) else { return }
        schedule(cause) { [weak self] in self?.flush(cause) }
    }

    /// One flush of `cause` maps all its rows when the person or the frontend caused them, else a slice.
    private func rowsPerFlush(_ cause: ObservationCause) -> Int {
        cause >= .frontend ? .max : rowsPerBudgetedFlush
    }

    /// Maps again the next rows `cause` marked (a row raised to a higher cause since is that
    /// cause's, and a row mapped since is skipped).
    private func flush(_ cause: ObservationCause) {
        let ids = lanes[cause.rawValue].take(rowsPerFlush(cause)) { self.dirty[$0] == cause }
        guard !ids.isEmpty else { return }
        for id in ids { dirty[id] = nil }
        var changed: [SidebarWorkspace] = []
        SidebarPerfCounters.timed {
            for id in ids {
                guard let entry = entries[id], !entry.armed else { continue }
                let row = arm(id, entry)
                observations?.evaluated()
                guard row != entry.row else { continue }
                observations?.applied()
                entry.row = row
                changed.append(row)
            }
        }
        if !changed.isEmpty { onChange?(changed) }
    }
}

/// One cause's dirty rows of a ``SidebarRowFeed``, in marking order, and its scheduled flushes: each
/// flush takes up to its slice of rows, and a mark that finds no room left in the scheduled ones
/// asks for one more.
private struct SidebarRowLane {
    private var ids: [WorkspaceID] = []
    private var head = 0
    /// Rows the scheduled flushes can still take before another must be scheduled.
    private var room = 0
    /// Flushes scheduled and not run yet.
    private var scheduled = 0

    /// Adds `id`; true when the caller must schedule a flush for it.
    mutating func add(_ id: WorkspaceID, rowsPerFlush: Int) -> Bool {
        ids.append(id)
        let needsFlush = room == 0
        if needsFlush {
            room = rowsPerFlush
            scheduled += 1
        }
        room -= 1
        return needsFlush
    }

    /// One scheduled flush runs: the next `limit` rows still marked by this lane's cause (`isMarked`).
    mutating func take(_ limit: Int, isMarked: (WorkspaceID) -> Bool) -> [WorkspaceID] {
        scheduled = max(0, scheduled - 1)
        if scheduled == 0 { room = 0 }
        var taken: [WorkspaceID] = []
        while head < ids.count, taken.count < limit {
            let id = ids[head]
            head += 1
            if isMarked(id) { taken.append(id) }
        }
        if head == ids.count {
            ids.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= ids.count {
            ids.removeFirst(head)
            head = 0
        }
        return taken
    }

    /// Forgets the rows (the feed reset); flushes already scheduled still run and find none.
    mutating func dropRows() {
        ids.removeAll()
        head = 0
    }
}
