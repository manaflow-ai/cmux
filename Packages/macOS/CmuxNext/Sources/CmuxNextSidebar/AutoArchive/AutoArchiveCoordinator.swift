import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// What auto-archive reads from and asks of the App (the one place that knows windows, daemons and
/// the sidebar's cards): the composition root conforms, tests pass a fake.
@MainActor
public protocol AutoArchiveHost: AnyObject {
    /// One candidate per workspace the sidebar document places. The host fills `item`, `workspace`,
    /// `title`, `lastActive` (the newest output, agent update or notification it knows), the
    /// workspace's own `pinned`, `running` and `needsAttention`; the coordinator adds the rest.
    func autoArchiveCandidates() -> [AutoArchivePlanner.Candidate]
    /// The workspaces shown in any window now. Read inside an observation scope: a change re-reads it.
    func autoArchiveShownWorkspaces() -> Set<String>
    /// The current `workspaces.autoArchive` settings as a policy. Read inside an observation scope.
    func autoArchivePolicy() -> AutoArchivePolicy
    /// Shows a toast in the active window; `undo` runs on its Undo button (or Cmd-Z while it shows).
    func autoArchiveToast(_ message: String, undo: @escaping @MainActor () -> Void)
    /// Shows `card` in the sidebar until the person answers; the id of the button they clicked,
    /// nil for the x.
    func autoArchiveAsk(_ card: SidebarNoticeCard) async -> String?
    /// Writes `workspaces.autoArchive.style` (the card's Always Archive picks ``AutoArchivePolicy/Style/quiet``).
    func autoArchiveSetStyle(_ style: AutoArchivePolicy.Style) async
    /// The document item that places workspace `id` (a dictionary read); nil while it is not placed.
    func autoArchiveItem(workspace id: String) -> String?
}

/// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): follows `workspaces.autoArchive`, records
/// when each workspace was last shown, and, at the next deadline the ``AutoArchivePlanner`` names
/// (one wakeup, never a poll), archives the idle workspaces or suggests them, per the style. A
/// workspace it archived comes back when it is shown again. Archive Idle Workspaces (``sweep()``)
/// runs the same plan on request. Every archive is the document's `archive` op: one undo step, the
/// groups follow their members in the reducer, and the toast's Undo takes it back.
@MainActor
public final class AutoArchiveCoordinator {
    private let host: any AutoArchiveHost
    private let document: () -> (any AutoArchiveDocument)?
    private let ledgerStore: AutoArchiveLedgerStore
    private let now: @MainActor () -> Date
    private let pass: DemandTimer
    private let flush: DemandTimer
    private let planner = AutoArchivePlanner()
    private var ledger = AutoArchiveLedger()
    private var loaded = false
    private var follows: [Task<Void, Never>] = []
    private var card: Task<Void, Never>?
    #if DEBUG
    /// DEBUG only: seconds added to the clock, so a fresh session looks idle (the gallery tours).
    public var debugClockSkew: TimeInterval = 0
    #endif

    /// The first pass waits this long after launch, so it never competes with the launch's work.
    public static let launchDelay: Duration = .seconds(30)
    /// Not Now keeps the card away this long.
    public static let snooze: TimeInterval = 86_400
    /// The ledger is saved at most this often while shows keep coming (a lost minute of shows only
    /// delays an archive).
    public static let flushDelay: Duration = .seconds(300)

    /// - Parameters:
    ///   - document: the app's sidebar document while it is active (its own store, from the composition root).
    ///   - ledgerStore: where the last-seen ledger lasts across launches.
    ///   - clock: drives the pass and save deadlines (tests pass a manual clock).
    ///   - now: the wall clock the idle times are measured on.
    public init(host: any AutoArchiveHost,
                document: @escaping () -> (any AutoArchiveDocument)?,
                ledgerStore: AutoArchiveLedgerStore, clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.host = host
        self.document = document
        self.ledgerStore = ledgerStore
        self.now = now
        pass = DemandTimer(owner: "auto-archive-pass", clock: clock)
        flush = DemandTimer(owner: "auto-archive-ledger", clock: clock)
    }

    /// Loads the ledger, follows the shown workspaces and the settings, and schedules the first pass.
    public func start() {
        // task-owner: the coordinator's follows; cancelled in stop()
        follows.append(Task { @MainActor [weak self] in
            guard let self else { return }
            ledger = ledgerStore.load()
            loaded = true
            for await shown in ObservationStream({ [weak self] in self?.host.autoArchiveShownWorkspaces() ?? [] }) {
                noteShown(shown)
            }
        })
        // task-owner: the settings follow; cancelled in stop()
        follows.append(Task { @MainActor [weak self] in
            var first = true
            for await _ in ObservationStream({ [weak self] in self?.host.autoArchivePolicy() ?? AutoArchivePolicy() }) {
                guard let self else { return }
                card?.cancel()
                schedulePass(after: first ? Self.launchDelay : .seconds(1))
                first = false
            }
        })
    }

    /// Stops following, cancels the deadlines and saves the ledger.
    public func stop() {
        follows.forEach { $0.cancel() }
        follows = []
        card?.cancel()
        pass.cancel()
        flush.cancel()
        if loaded { save() }
    }

    /// Archive Idle Workspaces: archives every workspace idle past its time now, whatever the style
    /// (a group's Never still keeps its members). Returns how many it archived.
    @discardableResult
    public func sweep() throws(AutoArchiveRefusal) -> Int {
        let due = plan(.sweep).due
        guard !due.isEmpty else { throw AutoArchiveRefusal(message: AutoArchiveStrings.nothingIdle) }
        try archive(due.map(\.item))
        return due.count
    }

    /// The workspaces Archive Idle Workspaces would archive now (the review list).
    public func idleNow() -> [AutoArchivePlanner.Candidate] { plan(.sweep).due }

    /// Every archived workspace the document places (by hand or on its own, or under an archived
    /// group), last used first: the Archived page's rows.
    public func archivedWorkspaces() -> [AutoArchivePlanner.Candidate] {
        guard let store = activeStore() else { return [] }
        let candidates = host.autoArchiveCandidates()
        let rows = AutoArchiveRules.archived(store.records, candidates: candidates, seen: ledger.seen) ?? []
        return rows.compactMap { reply in
            guard candidates.indices.contains(reply.index) else { return nil }
            var row = candidates[reply.index]
            row.archived = true
            row.lastActive = reply.lastActive.map(Date.init(timeIntervalSince1970:))
            return row
        }
    }

    /// Runs the background pass now (tests, and the deadline).
    public func runPass() {
        let policy = host.autoArchivePolicy()
        let plan = plan(.background)
        guard let pass = AutoArchiveRules.pass(policy, due: plan.due.count, nextCheck: plan.nextCheck, now: clockNow()) else { return }
        if let after = pass.recheckAfter { schedulePass(after: .seconds(after)) }
        switch pass.action {
        case .archive:
            // Nobody here asked for this pass: a refusal is logged, never a toast (Leo, 2026-11-14).
            guard let store = activeStore() else { return }
            try? store.automatically { () throws(AutoArchiveRefusal) in try archive(plan.due.map(\.item)) }
        case .suggest:
            suggest(plan.due, days: pass.days)
        case .none:
            break
        }
    }

    // MARK: - Plan

    /// The planner's call (Rust `auto_archive_plan`) over the host's candidates, the document's marks
    /// and groups, and the ledger's sights and snooze.
    private func plan(_ trigger: AutoArchivePlanner.Trigger) -> AutoArchivePlanner.Plan {
        guard let store = activeStore() else { return AutoArchivePlanner.Plan() }
        let records = store.records
        let shown = host.autoArchiveShownWorkspaces()
        let time = clockNow()
        var candidates = host.autoArchiveCandidates()
        // The document's and the windows' marks and each candidate's groups (Rust `sidebar_archive_marks`); a refused
        // call plans nothing, as a refused plan does.
        guard let marks = AutoArchiveRules.marks(records, candidates: candidates, shown: shown) else { return AutoArchivePlanner.Plan() }
        var seen: [String: Date] = [:]
        for (index, mark) in marks.marks.enumerated() {
            candidates[index].shown = mark.shown
            candidates[index].archived = mark.archived
            candidates[index].pinned = mark.pinned
            candidates[index].groups = mark.groups
            seen[candidates[index].workspace] = ledger.seen[candidates[index].workspace].map(Date.init(timeIntervalSince1970:))
        }
        let snoozedUntil = ledger.snoozedUntil.map(Date.init(timeIntervalSince1970:))
        let plan = planner.plan(candidates, seen: seen, rules: marks.rules.mapValues(\.rule), policy: host.autoArchivePolicy(),
                                trigger: trigger, now: time, snoozedUntil: snoozedUntil)
        // First sight: the clock starts now, so a workspace is never idle on arrival (Rust `auto_archive_ledger`).
        if let planned = AutoArchiveRules.planned(ledger, firstSight: plan.firstSight, snoozed: plan.snoozed,
                                                  workspaces: Set(candidates.map(\.workspace)), items: Set(records.items.keys), now: time) {
            ledger = planned.ledger
            if planned.dirty { markDirty() }
        }
        return plan
    }

    // MARK: - Act

    private func archive(_ items: [String]) throws(AutoArchiveRefusal) {
        guard let store = activeStore() else { throw AutoArchiveRefusal(message: AutoArchiveStrings.needsDocument) }
        do throws(SidebarDocSendRefusal) {
            try store.setArchived(items, archived: true, title: AutoArchiveStrings.undoTitle)
        } catch {
            throw AutoArchiveRefusal(message: error.message)
        }
        if let archived = AutoArchiveRules.archived(ledger, items: items) { ledger = archived }
        markDirty()
        host.autoArchiveToast(AutoArchiveStrings.archived(items.count)) { [weak self] in self?.restore(items) }
    }

    /// The document items of `workspaces` that Archive Other Workspaces, Archive Workspaces Above or
    /// Below would archive, in that order: placed, not pinned (top-level Pinned or pinned in a group)
    /// and not archived yet, by itself or under an archived group.
    public func archivableItems(workspaces: [String]) -> [String] {
        guard let records = activeStore()?.records else { return [] }
        return AutoArchiveRules.archivable(records, items: workspaces.map { host.autoArchiveItem(workspace: $0) }) ?? []
    }

    /// Archives `workspaces` a person named (the bulk archive rows): their ``archivableItems(workspaces:)``
    /// as one undo step, and a toast whose Undo brings the whole batch back. Returns how many it
    /// archived; 0 sends nothing. Unlike the sweep it leaves the ledger alone: a hand archive is no
    /// auto-archive, so showing the workspace again does not bring it back.
    @discardableResult
    public func archive(workspaces: [String]) throws(AutoArchiveRefusal) -> Int {
        guard let store = activeStore() else { throw AutoArchiveRefusal(message: AutoArchiveStrings.needsDocument) }
        let items = archivableItems(workspaces: workspaces)
        guard !items.isEmpty else { return 0 }
        do throws(SidebarDocSendRefusal) {
            try store.setArchived(items, archived: true, title: AutoArchiveStrings.archiveWorkspacesTitle)
        } catch {
            throw AutoArchiveRefusal(message: error.message)
        }
        host.autoArchiveToast(AutoArchiveStrings.archivedByHand(items.count)) { [weak self] in self?.restore(items) }
        return items.count
    }

    /// Unarchives `items` (the toast's Undo, Restore in the Archived list).
    public func restore(_ items: [String]) {
        guard let store = activeStore(), !items.isEmpty else { return }
        try? store.setArchived(items, archived: false, title: AutoArchiveStrings.restoreTitle)
        let workspaces = items.compactMap { item -> String? in
            if case let .workspace(ref)? = store.records.items[item]?.body { ref.workspaceID } else { nil }
        }
        if let restored = AutoArchiveRules.restored(ledger, items: items, workspaces: workspaces, now: clockNow()) { ledger = restored }
        markDirty()
    }

    /// The Tidy Up card, as small as it can be (Lawrence 18515, gallery pick T3): "2 idle workspaces",
    /// the names, Archive and an inline "Always" switch; the x is Not Now (a day's snooze). Flipping Always turns
    /// on `workspaces.autoArchive.style` `quiet` and archives these now.
    private func suggest(_ due: [AutoArchivePlanner.Candidate], days: Int) {
        guard card == nil, let names = AutoArchiveRules.card(due.map(\.title)) else { return }
        var lines = names.lines
        if let more = names.more { lines.append(AutoArchiveStrings.andMore(more)) }
        let card = SidebarNoticeCard(
            id: "auto-archive.suggest", symbol: "archivebox",
            title: AutoArchiveStrings.cardQuestion(due.count), lines: lines,
            actions: [SidebarNoticeCard.Action(id: Self.archiveAction, title: AutoArchiveStrings.cardArchive, prominent: true),
                      SidebarNoticeCard.Action(id: Self.alwaysAction, title: AutoArchiveStrings.cardAlways, isSwitch: true)],
            dismissLabel: AutoArchiveStrings.cardNotNow)
        let items = due.map(\.item)
        // task-owner: the one open suggestion; cancelled by a settings change or stop()
        self.card = Task { @MainActor [weak self] in
            guard let self else { return }
            let chosen = await host.autoArchiveAsk(card)
            self.card = nil
            guard !Task.isCancelled else { return }
            switch chosen {
            case Self.archiveAction?, Self.alwaysAction?:
                if chosen == Self.alwaysAction { await host.autoArchiveSetStyle(.quiet) }
                // Only what is still idle: the person may have opened one while the card showed.
                let still = AutoArchiveRules.stillDue(items, due: plan(.sweep).due.map(\.item)) ?? []
                try? archive(still)
            default:
                var after = Self.snooze
                if let snoozed = AutoArchiveRules.snoozed(ledger, now: clockNow()) {
                    ledger = snoozed.ledger
                    after = snoozed.recheckAfter
                    markDirty()
                }
                schedulePass(after: .seconds(after))
            }
        }
    }

    static let archiveAction = "archive"
    static let alwaysAction = "always"

    // MARK: - Shows

    func noteShown(_ shown: Set<String>) {
        // O(shown windows) per switch: the item lookup runs only while something is auto-archived, and only the shown
        // workspaces' sights cross to Rust (`auto_archive_ledger` `shown`).
        let lookup = !ledger.autoArchived.isEmpty
        let records = lookup ? activeStore()?.records : nil
        let rows = shown.map { workspace in
            let item = lookup ? host.autoArchiveItem(workspace: workspace) : nil
            return AutoArchiveRules.Shown(workspace: workspace, item: item,
                                          archived: item.map { records?.isArchived(item: $0) == true } ?? false)
        }
        guard let reply = AutoArchiveRules.shown(ledger, rows, now: clockNow()) else { return }
        ledger = reply.ledger
        if !reply.back.isEmpty { restore(reply.back) }
        if reply.dirty { markDirty() }
    }

    // MARK: - Deadlines

    private func schedulePass(after delay: Duration) {
        pass.schedule(after: delay) { @MainActor [weak self] in self?.runPass() }
    }

    private func markDirty() {
        flush.scheduleIfIdle(after: Self.flushDelay) { @MainActor [weak self] in self?.save() }
    }

    private func save() { ledgerStore.save(ledger) }

    /// The wall clock, plus the DEBUG skew (Debug > Age Workspaces for Auto-Archive, the gallery tours).
    private func clockNow() -> Date {
        #if DEBUG
        now().addingTimeInterval(debugClockSkew)
        #else
        now()
        #endif
    }

    private func activeStore() -> (any AutoArchiveDocument)? { document() }
}
