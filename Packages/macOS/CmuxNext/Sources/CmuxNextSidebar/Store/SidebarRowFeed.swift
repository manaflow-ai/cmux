import Foundation
import Observation

/// Row content observed one workspace at a time, so a status change of one
/// workspace (agent status, OSC 7501, title, unread, progress, favicon) maps
/// that one row again and never re-runs the structural sidebar pass.
///
/// The structural pass (an `ObservationStream` over order, groups, pins,
/// membership and machines) names each listed workspace with `row(_:make:)`:
/// it gets the last mapped row (or a stub for a new one) and reads nothing
/// observable, so it does not observe any row's status. After the pass,
/// outside its tracking, `fill` maps the new rows under their own
/// observation and refreshes the others with the pass's new inputs. A change
/// a row read marks it dirty; one flush per main-actor turn maps the dirty
/// rows again and hands the changed ones to `onChange`.
@MainActor
public final class SidebarRowFeed {
    public typealias Make = @MainActor () -> SidebarWorkspace

    private final class Entry {
        var make: Make
        var row: SidebarWorkspace
        /// The row's mapping has an observation armed.
        var armed = false
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
    /// Rows mapped again since the last structural pass (the next `fill` maps only new rows).
    private var named: [WorkspaceID] = []
    /// Changed rows, at most once per main-actor turn.
    public var onChange: (([SidebarWorkspace]) -> Void)?

    public init() {}

    /// Starts a structural pass (call first in the pass's tracked closure).
    public func beginPass() {
        pass &+= 1
        named.removeAll(keepingCapacity: true)
    }

    /// The row of `id` for the structural pass: the last mapped row, or a
    /// stub until `fill` maps it. `make` maps it from its store; it runs
    /// later, outside the pass's tracking.
    public func row(_ id: WorkspaceID, machine: MachineID, make: @escaping Make) -> SidebarWorkspace {
        named.append(id)
        if let entry = entries[id] {
            entry.make = make
            entry.pass = pass
            return entry.row
        }
        let stub = SidebarWorkspace(id: id, machineID: machine, title: "")
        entries[id] = Entry(make: make, row: stub, pass: pass)
        return stub
    }

    /// `sections` with every row the last pass named mapped now: a new row
    /// under its own observation, a known one again with the pass's inputs
    /// (muted set, page faces, tab selection). Forgets rows the pass did not
    /// name. Each row keeps its row state from `sections`. Call outside any
    /// observation tracking.
    public func fill(_ sections: [SidebarSection]) -> [SidebarSection] {
        SidebarPerfCounters.add(.rebuilds)
        return SidebarPerfCounters.timed { fillNow(sections) }
    }

    private func fillNow(_ sections: [SidebarSection]) -> [SidebarSection] {
        for (id, entry) in entries where entry.pass != pass { entries[id] = nil }
        var rows: [SidebarWorkspace] = []
        rows.reserveCapacity(named.count)
        for id in named {
            guard let entry = entries[id] else { continue }
            entry.row = entry.armed ? entry.make() : arm(id, entry)
            rows.append(entry.row)
        }
        dirty.subtract(named)
        return SidebarRowIndex.patching(rows, in: sections)
    }

    /// Maps `entry` under an observation that marks it dirty on its next change.
    private func arm(_ id: WorkspaceID, _ entry: Entry) -> SidebarWorkspace {
        entry.armed = true
        return withObservationTracking { entry.make() } onChange: { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.markDirty(id) } // main-proof: checked on the line above
            } else {
                Task { @MainActor [weak self] in self?.markDirty(id) }
            }
        }
    }

    private func markDirty(_ id: WorkspaceID) {
        guard let entry = entries[id] else { return }
        entry.armed = false
        dirty.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        // task-owner: the feed; one flush per main-actor turn after the store's batch applies
        Task { @MainActor [weak self] in self?.flush() }
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
