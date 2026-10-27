public import CmuxNextWakeups
import Foundation
import Observation

/// Row content observed one workspace at a time, so a status change of one workspace (agent status,
/// OSC 7501, title, unread, progress, favicon) maps that one row again and never re-runs the
/// structural sidebar pass.
///
/// The structural pass (an `ObservationStream` over order, groups, pins, membership and machines)
/// names each listed workspace with `row(_:make:)`: it gets the last mapped row (or a stub for a new
/// one) and reads nothing observable. After the pass, outside its tracking, `fill` maps the new rows
/// under their own observation. A known row is already current: anything it read would have marked it
/// dirty. Only when the pass's by-value inputs change (`beginPass`) is every row mapped again. A change
/// a row read marks it dirty; one flush (per display frame in the app) maps the dirty rows again (each
/// observation fires once and is armed again, so none piles up) and hands the changed ones to `onChange`.
///
/// Each row has one live observation at most: before a row is observed again while its observation is
/// live, and when a row is forgotten, the feed fires that observation through `SidebarRowWatch.cancel()`,
/// so the registrar drops it, and the stale callback is ignored by its generation.
///
/// Each dirty row keeps the cause of the change that marked it, and each cause has its own flushes
/// (``init(cause:rowsPerBudgetedFlush:schedule:)``), which map only the rows of that cause, in the order
/// they were marked: a person's row change neither waits behind nor pays for the rows automation marked.
/// A program or automation flush maps a bounded slice of rows, so a burst spreads over frames.
///
/// A list that tells the feed what it draws (``watch(drawn:_:)``, ``watch(_:)``) has only the rows on screen
/// armed, as Chrome keeps current only the tiles near the viewport and re-rasterizes a tile only when
/// it was invalidated (`cc/tiles/tile_manager.cc`, `cc/tiles/picture_layer_tiling.cc`). A drawn row
/// off screen keeps its last mapped row and a sentinel: an observation whose change maps nothing and
/// only marks the row stale. A stale row is mapped once when it comes into the overscan (a `frontend`
/// flush, as Chrome prepaints the tiles it is about to draw), and at once, in the same turn, when it
/// comes on screen; a row that did not change is mapped neither time. Rows the list does not draw as
/// rows of their own (a band tile, a collapsed group's member) stay armed. An off-screen member of an
/// open group whose header is on screen is mapped once per change in the budgeted automation lane, so
/// the header's roll-up catches up behind every other row. While the sidebar's `VisibilityNode` is not
/// visible no row is armed.
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
        /// What the row's observation does on its next change.
        var state = WatchState.stale
        /// The armed observation's generation; a callback of an older one is stale.
        var generation: UInt64 = 0
        let watch = SidebarRowWatch()
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
    /// The rows the list draws as rows of their own, which scroll away; nil observes every row.
    private var drawn: Set<WorkspaceID>?
    /// What the list shows of the rows it draws.
    private var viewport = Viewport()
    /// The sidebar's visibility node is not visible: no row is armed.
    private var hidden = false
    private var visibilityToken: VisibilitySubscription?
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
        // main-hop-allow: the rows' observation primitive (p06 task 329 allow-list): this default serves a feed made with no schedule (tests); the app hands FrameBatcher's display frame
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
        (drawn, viewport, hidden, visibilityToken) = (nil, Viewport(), false, nil)
        for index in lanes.indices { lanes[index].dropRows() }
    }

    /// What the list draws after a layout: `drawn`, its rows of their own (nil observes every row
    /// again), and what it shows of them. Visits the rows whose drawn or shown place moved (every row
    /// only when the list starts or stops telling).
    public func watch(drawn rows: Set<WorkspaceID>?, _ shown: Viewport) {
        guard rows != drawn else { return watch(shown) }
        let old = drawn
        drawn = rows
        let moved = shown.moved(from: viewport)
        viewport = shown
        guard let old, let rows else {
            // A reader of every row starts (a filter, Group by Status, the rail): the stale rows are mapped now, in its turn.
            if rows == nil { refreshAll() }
            return follow(Array(entries.keys))
        }
        follow(Array(old.symmetricDifference(rows).union(moved)))
    }

    /// What the list shows of the rows it draws, after a scroll: a row that leaves the screen keeps a
    /// sentinel, a stale one that comes near is mapped once, and one that comes on screen is mapped
    /// now. O(rows that came or left).
    public func watch(_ shown: Viewport) {
        let moved = shown.moved(from: viewport)
        viewport = shown
        guard drawn != nil, !moved.isEmpty else { return }
        follow(Array(moved))
    }

    /// Follows `node`, the sidebar's visibility (nil stops; its owner keeps it alive): while it is not
    /// visible no row is armed; when it shows again each row is armed or mapped as its place asks. One
    /// visit of the rows per flip.
    public func follow(visibility node: VisibilityNode?) {
        visibilityToken = node?.subscribe(owner: "SidebarRowFeed") { [weak self] visibility in
            self?.setHidden(visibility != .visible)
        }
        setHidden(node.map { !$0.isVisible } ?? false)
    }

    private func setHidden(_ value: Bool) {
        guard value != hidden else { return }
        hidden = value
        follow(Array(entries.keys))
    }

    /// Maps now every row that may be stale (it changed while off screen) and reports the changed
    /// ones in this turn, for a reader of every row's content in ``SidebarModel/sections`` (a sort by
    /// name). Each row then stays as its place asks: an off-screen one keeps a sentinel.
    public func refreshAll() {
        mapNow(entries.compactMap { id, entry in entry.state == .stale ? id : nil })
    }

    private func level(of id: WorkspaceID) -> Level {
        if hidden { return .away }
        guard let drawn, drawn.contains(id), !viewport.visible.contains(id) else { return .armed }
        if viewport.rollUp.contains(id) { return .rolledUp }
        return viewport.near.contains(id) ? .followed : .away
    }

    /// Brings each of `ids` to what its place asks: an armed row that left the screen keeps a sentinel
    /// (it is current until its next change), a sentinel that came back is armed again with no map, and
    /// a stale row is mapped, now when it is on screen, else once in a `frontend` flush (one queued at a
    /// lower cause moves up to it), or in the automation lane for a header's roll-up.
    private func follow(_ ids: [WorkspaceID]) {
        var now: [WorkspaceID] = []
        for id in ids {
            guard let entry = entries[id] else { continue }
            switch (entry.state, level(of: id)) {
            case (.armed, .followed), (.armed, .away), (.armed, .rolledUp):
                entry.state = .sentinel
                observations?.disarmed()
            case (.sentinel, .armed):
                entry.state = .armed
                observations?.armed()
            case (.stale, .armed) where viewport.visible.contains(id):
                now.append(id)
            case (.stale, .armed), (.stale, .followed):
                enqueue(id, cause: .frontend)
            case (.stale, .rolledUp):
                enqueue(id, cause: .automation)
            default:
                break
            }
        }
        mapNow(now)
    }

    /// Maps `ids` now and reports the changed rows in this turn.
    private func mapNow(_ ids: [WorkspaceID]) {
        guard !ids.isEmpty else { return }
        var changed: [SidebarWorkspace] = []
        SidebarPerfCounters.timed {
            for id in ids {
                guard let entry = entries[id] else { continue }
                dirty[id] = nil
                if let row = remap(id, entry) { changed.append(row) }
            }
        }
        if !changed.isEmpty { onChange?(changed) }
    }

    /// Maps `entry` again and stores the row; returns it when it differs from the last one.
    private func remap(_ id: WorkspaceID, _ entry: Entry) -> SidebarWorkspace? {
        let row = arm(id, entry)
        let differs = row != entry.row
        observations?.evaluated(applied: differs)
        guard differs else { return nil }
        entry.row = row
        return row
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
            let place = level(of: id)
            // A row whose content changed since its last map (dirty) keeps that row here: the scheduled flush maps it
            // and sends it as a patch. Mapped here, a tick's status would ride this pass as a structural set (hitch17:
            // a sidebar reload and an anchored offset shift every 1-2 s under 50 ticking terminals).
            if place != .armed {
                // Off screen: a new row is mapped once under a sentinel (its title, folder and height place it); an
                // inputs change leaves a known row stale until it comes on screen.
                if entry.revision == 0 {
                    entry.row = arm(id, entry)
                } else if remap {
                    disarm(entry)
                } else if entry.state == .armed {
                    entry.state = .sentinel
                    observations?.disarmed()
                }
                if place == .rolledUp, entry.state == .stale { enqueue(id, cause: .automation) }
            } else if !remap, entry.state == .sentinel {
                entry.state = .armed // current since its last map: armed again with no map
                observations?.armed()
            } else if remap || (entry.state == .stale && dirty[id] == nil) {
                let row = arm(id, entry)
                // A re-map (an inputs change) is a re-read as in a flush; a new stub's first map is an arm only.
                if entry.revision != 0 { observations?.evaluated(applied: row != entry.row) }
                entry.row = row
            }
            // The pass holds this row already, unless it was a stub or was mapped again since.
            if entry.revision != entry.namedRevision { rows.append(entry.row) }
            entry.namedRevision = entry.revision
        }
        if remap, !dirty.isEmpty { for id in named { dirty[id] = nil } }
        return SidebarRowIndex.patching(rows, in: sections)
    }

    /// Maps `entry` under an observation that marks it dirty on its next change (only stale, a sentinel,
    /// when its place does not arm it); an observation still live is removed first (one per row).
    private func arm(_ id: WorkspaceID, _ entry: Entry) -> SidebarWorkspace {
        disarm(entry)
        entry.state = level(of: id) == .armed ? .armed : .sentinel
        if entry.state == .armed { observations?.armed() }
        let generation = entry.generation
        return entry.watch.track(entry.make) { [weak self] onMain in
            guard let self else { return }
            // An off-main write is no request's: no cause scope covers it.
            self.markDirty(id, generation: generation, cause: onMain ? self.cause() : .program)
        }
    }

    /// Removes `entry`'s armed observation: the write fires it (the registrar
    /// drops it) and the new generation makes its callback a no-op.
    private func disarm(_ entry: Entry) {
        entry.generation &+= 1
        guard entry.state != .stale else { return }
        if entry.state == .armed { observations?.disarmed() }
        entry.state = .stale
        entry.watch.cancel()
    }

    /// The row's observation fired, and so is gone: an armed row is queued with the change's cause, a header's
    /// roll-up member in the automation lane, and any other row is stale until it comes near.
    private func markDirty(_ id: WorkspaceID, generation: UInt64, cause: ObservationCause) {
        guard let entry = entries[id], entry.generation == generation else { return }
        if entry.state == .armed { observations?.disarmed() }
        entry.state = .stale
        switch level(of: id) {
        case .armed: enqueue(id, cause: cause)
        case .rolledUp: enqueue(id, cause: .automation)
        case .followed, .away: break
        }
    }

    /// Queues `id`'s row for a flush of `cause` (a row a higher cause queued stays that cause's).
    private func enqueue(_ id: WorkspaceID, cause: ObservationCause) {
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
                // A row that went off screen since it was queued stays stale until it comes near.
                guard let entry = entries[id], entry.state == .stale, level(of: id) != .away else { continue }
                if let row = remap(id, entry) { changed.append(row) }
            }
        }
        if !changed.isEmpty { onChange?(changed) }
    }
}
