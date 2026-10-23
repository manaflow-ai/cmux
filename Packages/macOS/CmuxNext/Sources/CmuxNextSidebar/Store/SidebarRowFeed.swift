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
    private var dirty: Set<WorkspaceID> = []
    private var flushScheduled = false
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
    private let schedule: Schedule

    /// `schedule` defaults to the next main-actor turn.
    public init(schedule: Schedule? = nil) {
        // task-owner: the feed; one flush per main-actor turn after the store's batch applies
        self.schedule = schedule ?? { work in Task { @MainActor in work() } }
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
            if remap || (!entry.armed && !dirty.contains(id)) { entry.row = arm(id, entry) }
            // The pass holds this row already, unless it was a stub or was mapped again since.
            if entry.revision != entry.namedRevision { rows.append(entry.row) }
            entry.namedRevision = entry.revision
        }
        if remap { dirty.subtract(named) }
        return SidebarRowIndex.patching(rows, in: sections)
    }

    /// Maps `entry` under an observation that marks it dirty on its next
    /// change; an observation still armed is removed first (one per row).
    private func arm(_ id: WorkspaceID, _ entry: Entry) -> SidebarWorkspace {
        disarm(entry)
        entry.armed = true
        let generation = entry.generation
        let cancel = entry.cancel
        return withObservationTracking {
            _ = cancel.epoch
            return entry.make()
        } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.markDirty(id, generation: generation) } // main-proof: checked on the line above
            } else {
                Task { @MainActor [weak self] in self?.markDirty(id, generation: generation) }
            }
        }
    }

    /// Removes `entry`'s armed observation: the write fires it (the registrar
    /// drops it) and the new generation makes its callback a no-op.
    private func disarm(_ entry: Entry) {
        entry.generation &+= 1
        guard entry.armed else { return }
        entry.armed = false
        entry.cancel.epoch &+= 1
    }

    private func markDirty(_ id: WorkspaceID, generation: UInt64) {
        guard let entry = entries[id], entry.generation == generation else { return }
        entry.armed = false
        dirty.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        schedule { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !dirty.isEmpty else { return }
        let ids = dirty
        dirty.removeAll(keepingCapacity: true)
        var changed: [SidebarWorkspace] = []
        SidebarPerfCounters.timed {
            for id in ids {
                guard let entry = entries[id], !entry.armed else { continue }
                let row = arm(id, entry)
                guard row != entry.row else { continue }
                entry.row = row
                changed.append(row)
            }
        }
        if !changed.isEmpty { onChange?(changed) }
    }
}
