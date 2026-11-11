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
///
/// A row the pass names no longer (its space is not the one the window shows) is parked while
/// ``keeps`` says its workspace may list here again: it stays mapped and observed, a change it hears only marks it
/// for its next map, and the pass that names it again gets it as it is, at no cost. A space switch then maps the
/// rows that changed while their space was hidden, not every row of the space on every switch (200 maps, each
/// with its own observation, for a list that draws about 29: "changing spaces in sidebar also feels kinda slow").
@MainActor
public final class SidebarRowFeed {
    /// Maps one row from its store; runs on the main actor (the feed and its callers are main-actor). A row in a
    /// batch (``SidebarRowBatch``, the sidebar row face) maps in two steps around its batch's one call: `stage` adds
    /// it and gives its slot, `finish` reads the reply's slot into the row. Every row the feed maps in one turn (a
    /// pass's new rows, a flush's dirty ones) stages, each batch runs once, then the rows finish.
    public struct Make {
        /// The batch the row maps in; nil: `finish` maps it alone.
        public let batch: (any SidebarRowBatch)?
        let stage: () -> Int
        let finish: (Int) -> SidebarWorkspace

        /// A row mapped alone, with no batch.
        public init(_ map: @escaping () -> SidebarWorkspace) {
            batch = nil
            stage = { 0 }
            finish = { _ in map() }
        }

        /// A row of `batch`: `stage` adds it and returns its slot, `finish` maps it from the reply's slot.
        public init(batch: any SidebarRowBatch, stage: @escaping () -> Int, finish: @escaping (Int) -> SidebarWorkspace) {
            self.batch = batch
            self.stage = stage
            self.finish = finish
        }

        /// This make with `transform` run on its row (in the finish step, so what it reads is the row's to observe).
        public func then(_ transform: @escaping (SidebarWorkspace) -> SidebarWorkspace) -> Self {
            let stage = stage, finish = finish
            guard let batch else { return Self { transform(finish(stage())) } }
            return Self(batch: batch, stage: stage, finish: { transform(finish($0)) })
        }

        /// The row now, in a batch of one; nil when its batch could not run.
        public func callAsFunction() -> SidebarWorkspace? { Self.rows([self]).first ?? nil }

        /// The rows of `makes` in order: each batch begun, its rows staged, run once, then its rows finished, one
        /// batch at a time (batches may share buffers). Nil for a row whose batch could not run. `observing` runs each
        /// row's stage and finish (the feed observes each under the row's own observation).
        public static func rows(_ makes: [Self], observing: (Int, () -> Void) -> Void = { _, body in body() }) -> [SidebarWorkspace?] {
            SidebarPerfCounters.add(.rowsMade, makes.count)
            var rows = [SidebarWorkspace?](repeating: nil, count: makes.count)
            var batches: [(batch: any SidebarRowBatch, members: [Int])] = []
            for (index, make) in makes.enumerated() {
                guard let batch = make.batch else {
                    observing(index) { rows[index] = make.finish(make.stage()) }
                    continue
                }
                if let at = batches.firstIndex(where: { $0.batch === batch }) {
                    batches[at].members.append(index)
                } else {
                    batches.append((batch, [index]))
                }
            }
            for (batch, members) in batches {
                batch.begin()
                var slots: [Int] = []
                slots.reserveCapacity(members.count)
                for index in members { observing(index) { slots.append(makes[index].stage()) } }
                guard batch.run() else { continue }
                for (index, slot) in zip(members, slots) { observing(index) { rows[index] = makes[index].finish(slot) } }
            }
            return rows
        }
    }

    private final class Entry {
        var make: Make
        /// The last mapped row; each write moves `revision`.
        var row: SidebarWorkspace { didSet { revision &+= 1 } }
        /// Moves with every write of `row`.
        var revision: UInt64 = 0
        /// The `revision` of the row the last pass got from `row(_:machine:make:)` (`fill` writes the row only
        /// when it moved since); `.max` for a stub, which `fill` always writes.
        var namedRevision: UInt64 = .max
        /// The row's mapping has its observations armed (none fired since it mapped).
        var armed = false
        /// One of its observations fired and another may still be registered (a batched row observes its stage
        /// and its finish apart): the next `disarm` fires the cancel signal to drop it.
        var lingering = false
        /// The armed observation's generation; a callback of an older one is stale.
        var generation: UInt64 = 0
        let cancel = SidebarRowWatchCancel()
        /// Its last map got no row (its batch could not run): nothing it read may tell it to map again.
        var unmapped = false
        /// The pass that last named the row.
        var pass: UInt64
        /// No pass names the row now and `keeps` held it: nothing draws it, so a change marks it and maps nothing.
        var parked = false

        init(make: Make, row: SidebarWorkspace, pass: UInt64) {
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
        /// No pass asks now and `keeps` held it: a change marks it stale and wakes nothing.
        var parked = false

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
    /// Whether a workspace no pass names now may list here again (the app: this window still owns it), so its row
    /// and its listing stay parked. False forgets them: a closed workspace, one moved to another window.
    private let keeps: @MainActor (WorkspaceID) -> Bool
    /// The parked rows and listings, apart from the ones the last pass named: a pass and its fill walk only the rows
    /// they list. And whether a check of the parked ones against `keeps` is scheduled.
    private var parkedEntries: [WorkspaceID: Entry] = [:]
    private var parkedListings: [WorkspaceID: Listing] = [:]
    private var parkedCheckScheduled = false

    /// `schedule` defaults to the next main-actor turn. `keeps` defaults to no workspace: a row no pass names is
    /// forgotten at once.
    public init(schedule: Schedule? = nil, keeps: @escaping @MainActor (WorkspaceID) -> Bool = { _ in false }) {
        // task-owner: the feed; one flush per main-actor turn after the store's batch applies
        self.schedule = schedule ?? { work in Task { @MainActor in work() } }
        self.keeps = keeps
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
            // A parked row was mapped with the old inputs: it maps again when a pass names it.
            forgetParked()
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
        forgetParked()
    }

    private func forgetParked() {
        for entry in parkedEntries.values { disarm(entry) }
        parkedEntries.removeAll()
        for listing in parkedListings.values { disarm(listing) }
        parkedListings.removeAll()
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
        if let listing = listings[id] ?? unparkedListing(id) {
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
    public func row(_ id: WorkspaceID, machine: MachineID, make: @escaping () -> SidebarWorkspace) -> SidebarWorkspace {
        row(id, machine: machine, make: Make(make))
    }

    /// ``row(_:machine:make:)`` for a row that may map in a batch.
    public func row(_ id: WorkspaceID, machine: MachineID, make: Make) -> SidebarWorkspace {
        named.append(id)
        if let entry = entries[id] ?? unparkedEntry(id) {
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
    /// them again when the pass's inputs changed). Parks or forgets the rows
    /// the pass did not name (`keeps`). Each row keeps its row state from
    /// `sections`. Call outside any observation tracking.
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
        var parkedNow = false
        for (id, entry) in entries where entry.pass != pass {
            entries[id] = nil
            // A row mapped with the inputs this pass replaced is not kept: no later pass would map it again.
            guard !inputsChanged, keeps(id) else {
                disarm(entry)
                continue
            }
            // Its pending patch has no row to land on; it maps when a pass names it again (`armed` is false).
            (entry.parked, parkedNow) = (true, true)
            dirty.remove(id)
            parkedEntries[id] = entry
        }
        // Also while any row is parked: a parked workspace that closed or left the window tells nobody (no row parks, none hears it).
        if armListings() || parkedNow || !parkedEntries.isEmpty || !parkedListings.isEmpty { scheduleParkedCheck() }
        var rows: [SidebarWorkspace] = []
        let remap = inputsChanged
        inputsChanged = false
        // A row whose content changed since its last map (dirty) keeps that row here: the scheduled flush maps it
        // and sends it as a patch. Mapped here, a tick's status would ride this pass as a structural set (hitch17:
        // a sidebar reload and an anchored offset shift every 1-2 s under 50 ticking terminals).
        let due = named.filter { id in entries[id].map { remap || (!$0.armed && !dirty.contains(id)) } ?? false }
        for (entry, row) in map(due) { entry.row = row }
        for id in named {
            guard let entry = entries[id] else { continue }
            // The pass holds this row already, unless it was a stub or was mapped again since.
            if entry.revision != entry.namedRevision { rows.append(entry.row) }
            entry.namedRevision = entry.revision
        }
        if remap { dirty.subtract(named) }
        return SidebarRowIndex.patching(rows, in: sections)
    }

    /// Maps the rows of `ids` (each once) under observations that mark each dirty on its next change, every batch in
    /// one call (``Make/rows(_:observing:)``); a row's observations still armed are removed first. A batched row is
    /// observed twice, its stage and its finish, both under its cancel signal. A row whose batch could not run is not
    /// in the result: it keeps its last row, its stage stays observed, and the next change it read maps it again
    /// (or the pass that shows its space again: `unparkedEntry`).
    private func map(_ ids: [WorkspaceID]) -> [(Entry, SidebarWorkspace)] {
        var seen = Set<WorkspaceID>(), picked: [(id: WorkspaceID, entry: Entry)] = []
        for id in ids where seen.insert(id).inserted {
            guard let entry = entries[id] else { continue }
            disarm(entry)
            entry.armed = true
            SidebarPerfCounters.add(.rowMaps)
            picked.append((id, entry))
        }
        let rows = Make.rows(picked.map(\.entry.make)) { index, body in
            let (id, entry) = picked[index]
            let generation = entry.generation
            let cancel = entry.cancel
            withObservationTracking {
                _ = cancel.epoch
                body()
            } onChange: { [weak self] in
                MainDelivery().run { self?.markDirty(id, generation: generation) }
            }
        }
        return zip(picked, rows).compactMap { pick, row in
            pick.entry.unmapped = row == nil
            return row.map { (pick.entry, $0) }
        }
    }

    /// Removes `entry`'s armed observations: the write fires them (the registrar
    /// drops them) and the new generation makes their callbacks no-ops.
    private func disarm(_ entry: Entry) {
        entry.generation &+= 1
        guard entry.armed || entry.lingering else { return }
        entry.armed = false
        entry.lingering = false
        entry.cancel.epoch &+= 1
    }

    /// Parks or forgets the listings the last pass did not ask for (true when it parked one) and observes the ones
    /// it ran.
    private func armListings() -> Bool {
        var parkedNow = false
        for (id, listing) in listings where listing.pass != pass {
            listings[id] = nil
            guard keeps(id) else {
                disarm(listing)
                continue
            }
            (listing.parked, parkedNow) = (true, true)
            staleListings.remove(id)
            parkedListings[id] = listing
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
        return parkedNow
    }

    /// The parked rows and listings whose workspace `keeps` holds no longer are forgotten. It runs after a fill
    /// while any is parked and after a change one of them heard, never in an input's turn.
    private func scheduleParkedCheck() {
        guard !parkedCheckScheduled else { return }
        parkedCheckScheduled = true
        schedule { [weak self] in self?.checkParked() }
    }

    private func checkParked() {
        parkedCheckScheduled = false
        for (id, entry) in parkedEntries where !keeps(id) {
            disarm(entry)
            parkedEntries[id] = nil
        }
        for (id, listing) in parkedListings where !keeps(id) {
            disarm(listing)
            parkedListings[id] = nil
        }
    }

    /// The parked row of `id`, listed again by the pass that names it; nil when none is parked.
    private func unparkedEntry(_ id: WorkspaceID) -> Entry? {
        guard let entry = parkedEntries.removeValue(forKey: id) else { return nil }
        entry.parked = false
        if entry.unmapped { disarm(entry) } // the pass that names it maps it again, as it did before rows parked
        entries[id] = entry
        return entry
    }

    private func unparkedListing(_ id: WorkspaceID) -> Listing? {
        guard let listing = parkedListings.removeValue(forKey: id) else { return nil }
        listing.parked = false
        listings[id] = listing
        return listing
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
        guard let listing = listings[id] ?? parkedListings[id], listing.generation == generation else { return }
        listing.armed = false
        listing.stale = true
        // No pass reads a parked listing: the pass that asks again runs its rule (`lists`).
        guard !listing.parked else { return scheduleParkedCheck() }
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
        // A batched row's other observation firing on the same change finds it already dirty.
        guard let entry = entries[id] ?? parkedEntries[id], entry.generation == generation, entry.armed else { return }
        entry.armed = false
        entry.lingering = true
        SidebarPerfCounters.add(.rowInvalidations)
        // Nothing draws a parked row: it maps when a pass names it again, and sends no patch before.
        guard !entry.parked else { return scheduleParkedCheck() }
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
            for (entry, row) in map(ids.filter { id in entries[id].map { !$0.armed } ?? false }) where row != entry.row {
                entry.row = row
                changed.append(row)
            }
        }
        if !changed.isEmpty { onChange?(changed) }
    }
}
