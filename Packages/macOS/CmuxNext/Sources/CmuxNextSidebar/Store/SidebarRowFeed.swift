import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Observation

/// Read by every row mapping of `SidebarRowFeed` under its observation;
/// writing it fires (and so removes) that observation.
@Observable
fileprivate final class SidebarRowWatchCancel {
    var epoch: UInt64 = 0
}

/// Read by the structural pass once (``SidebarRowFeed/lists(_:rule:)``); moves when a workspace's listing flips.
@Observable
fileprivate final class SidebarListingFlips {
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

    /// Whether one workspace lists (``lists(_:rule:)``), observed apart from the structural pass.
    @MainActor private final class Listing {
        var value: Bool
        var rule: () -> Bool
        /// What the rule read changed since it last ran: the next pass or check runs it again.
        var stale = false
        /// The rule's observation is armed.
        var armed = false
        /// The armed observation's generation; a callback of an older one is stale.
        var generation: UInt64 = 0
        let cancel = SidebarRowWatchCancel()
        let tracking = SingleArmedTracking()
        /// The pass that last asked.
        var pass: UInt64

        init(value: Bool, rule: @escaping () -> Bool, pass: UInt64) {
            self.value = value
            self.rule = rule
            self.pass = pass
        }
    }

    private var entries: [WorkspaceID: Entry] = [:]
    private var listings: [WorkspaceID: Listing] = [:]
    /// Listings the pass ran (new or stale) that `fill` observes; listings whose observation fired, for the check.
    private var unarmedListings: [WorkspaceID] = []
    private var staleListings: Set<WorkspaceID> = []
    private var listingCheckScheduled = false
    private let listingFlips = SidebarListingFlips()
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
        if inputs != self.inputs {
            inputsChanged = true
            // A rule reads the pass's inputs by value too (whether the Home item shows the Home workspaces).
            for listing in listings.values { disarm(listing) }
            listings.removeAll()
            unarmedListings.removeAll()
            staleListings.removeAll()
        }
        self.inputs = inputs
    }

    /// Forgets every row and stops reporting (the window closed).
    public func reset() {
        onChange = nil
        for entry in entries.values { disarm(entry) }
        entries.removeAll()
        dirty.removeAll()
        for listing in listings.values { disarm(listing) }
        listings.removeAll()
        unarmedListings.removeAll()
        staleListings.removeAll()
    }

    /// Whether workspace `id` lists, by `rule`, for the structural pass. `rule` reads the workspace's own records (its
    /// tabs: a window's Home that the Home item shows, a chat whose session ended), and the pass must not: it walks
    /// every workspace, so a change inside ONE workspace (a tab opened, Cmd-N's first tab replacing its stand-in) ran
    /// the whole pass again (SIDEBAR ROWS STATUS 15571 cause b). The pass reads one flip counter here instead. The
    /// rule runs in the pass only for a new workspace or one whose records changed (its reads join that pass once);
    /// `fill` observes it apart, and a change it hears runs that one rule on the next flush, waking the pass only
    /// when the answer flips.
    public func lists(_ id: WorkspaceID, rule: @escaping () -> Bool) -> Bool {
        _ = listingFlips.epoch
        if let listing = listings[id] {
            listing.pass = pass
            listing.rule = rule
            guard listing.stale else { return listing.value }
            listing.stale = false
            listing.value = rule()
            if !listing.armed { unarmedListings.append(id) }
            return listing.value
        }
        let value = rule()
        listings[id] = Listing(value: value, rule: rule, pass: pass)
        unarmedListings.append(id)
        return value
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
        armListings()
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
        SidebarPerfCounters.add(.rowMaps)
        let generation = entry.generation
        let cancel = entry.cancel
        return withObservationTracking {
            _ = cancel.epoch
            return entry.make()
        } onChange: { [weak self] in
            MainDelivery().run { self?.markDirty(id, generation: generation) }
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

    /// Forgets the listings the last pass did not ask for and observes the ones it ran.
    private func armListings() {
        for (id, listing) in listings where listing.pass != pass {
            disarm(listing)
            listings[id] = nil
        }
        let ids = unarmedListings
        unarmedListings.removeAll(keepingCapacity: true)
        var flipped = false
        for id in ids {
            guard let listing = listings[id], !listing.armed else { continue }
            let value = arm(id, listing)
            if value != listing.value { (listing.value, flipped) = (value, true) }
        }
        if flipped { listingFlips.epoch &+= 1 }
    }

    /// Runs `listing`'s rule under an observation that marks it stale on its next change (one armed at most).
    private func arm(_ id: WorkspaceID, _ listing: Listing) -> Bool {
        disarm(listing)
        listing.armed = true
        listing.stale = false
        let generation = listing.generation
        let cancel = listing.cancel
        let rule = listing.rule
        return listing.tracking.track(shape: []) {
            _ = cancel.epoch
            return rule()
        } onChange: { [weak self] in
            MainDelivery().run { self?.markStale(id, generation: generation) }
        }
    }

    private func disarm(_ listing: Listing) {
        listing.generation &+= 1
        guard listing.armed else { return }
        listing.armed = false
        listing.cancel.epoch &+= 1
    }

    private func markStale(_ id: WorkspaceID, generation: UInt64) {
        guard let listing = listings[id], listing.generation == generation else { return }
        listing.armed = false
        listing.stale = true
        staleListings.insert(id)
        guard !listingCheckScheduled else { return }
        listingCheckScheduled = true
        schedule { [weak self] in self?.checkListings() }
    }

    /// Runs the stale listings' rules again (a pass may have run them first) and wakes the pass once if one flipped.
    private func checkListings() {
        listingCheckScheduled = false
        let ids = staleListings
        staleListings.removeAll(keepingCapacity: true)
        var flipped = false
        for id in ids {
            guard let listing = listings[id], listing.stale else { continue }
            let value = arm(id, listing)
            if value != listing.value { (listing.value, flipped) = (value, true) }
        }
        if flipped { listingFlips.epoch &+= 1 }
    }

    private func markDirty(_ id: WorkspaceID, generation: UInt64) {
        guard let entry = entries[id], entry.generation == generation else { return }
        entry.armed = false
        SidebarPerfCounters.add(.rowInvalidations)
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
