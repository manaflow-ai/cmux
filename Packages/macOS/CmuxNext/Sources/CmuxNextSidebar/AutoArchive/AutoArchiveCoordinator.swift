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
    /// The card lists at most this many names.
    static let cardNames = 5

    /// - Parameters:
    ///   - document: the active sidebar document (by default `SidebarDocStore.current` while active).
    ///   - ledgerStore: where the last-seen ledger lasts across launches.
    ///   - clock: drives the pass and save deadlines (tests pass a manual clock).
    ///   - now: the wall clock the idle times are measured on.
    public init(host: any AutoArchiveHost,
                document: @escaping () -> (any AutoArchiveDocument)? = { SidebarDocStore.current.flatMap { $0.isActive ? $0 : nil } },
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
        let records = store.records
        return host.autoArchiveCandidates().compactMap { candidate in
            let under = groups(of: candidate.item, in: records).contains { records.isArchived(item: $0) }
            guard records.isArchived(item: candidate.item) || under else { return nil }
            var row = candidate
            row.archived = true
            row.lastActive = [candidate.lastActive, ledger.lastSeen(candidate.workspace)].compactMap { $0 }.max()
            return row
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// Runs the background pass now (tests, and the deadline).
    public func runPass() {
        let policy = host.autoArchivePolicy()
        let plan = plan(.background)
        if let next = plan.nextCheck { schedulePass(after: .seconds(max(1, next.timeIntervalSince(clockNow())))) }
        guard !plan.due.isEmpty else { return }
        switch policy.style {
        case .quiet, .groups:
            try? archive(plan.due.map(\.item))
        case .suggest:
            suggest(plan.due, days: Int(policy.idleDays.rounded()))
        case .manual, .off:
            break
        }
    }

    // MARK: - Plan

    private func plan(_ trigger: AutoArchivePlanner.Trigger) -> AutoArchivePlanner.Plan {
        guard let store = activeStore() else { return AutoArchivePlanner.Plan() }
        let records = store.records
        let shown = host.autoArchiveShownWorkspaces()
        let time = clockNow()
        var rules: [String: SidebarDocAutoArchiveRule] = [:]
        for item in records.items.values where item.body.isGroup {
            if let rule = item.autoArchive { rules[item.id] = rule }
        }
        var candidates = host.autoArchiveCandidates()
        for index in candidates.indices {
            var candidate = candidates[index]
            let seen = ledger.lastSeen(candidate.workspace)
            candidate.lastActive = [candidate.lastActive, seen].compactMap { $0 }.max()
            if candidate.lastActive == nil {
                // First sight: the clock starts now, so a workspace is never idle on arrival.
                ledger.saw(candidate.workspace, at: time)
                markDirty()
            }
            candidate.shown = candidate.shown || shown.contains(candidate.workspace)
            candidate.archived = candidate.archived || records.isArchived(item: candidate.item)
            candidate.pinned = candidate.pinned || records.isPinned(item: candidate.item)
            candidate.groups = groups(of: candidate.item, in: records)
            candidates[index] = candidate
        }
        if trigger == .background, host.autoArchivePolicy().style == .suggest, let until = ledger.snoozedUntil,
           time.timeIntervalSince1970 < until {
            let deadline = Date(timeIntervalSince1970: until)
            var plan = planner.plan(candidates, rules: rules, policy: host.autoArchivePolicy(), trigger: trigger, now: time)
            plan.due = []
            plan.nextCheck = plan.nextCheck.map { max($0, deadline) } ?? deadline
            return plan
        }
        ledger.keep(only: Set(candidates.map(\.workspace)), items: Set(records.items.keys))
        return planner.plan(candidates, rules: rules, policy: host.autoArchivePolicy(), trigger: trigger, now: time)
    }

    /// The group items above `item`, nearest first (bounded by the document's nesting limit).
    private func groups(of item: String, in records: SidebarDocRecords) -> [String] {
        var out: [String] = []
        var parent = records.items[item]?.parent
        while let id = parent, out.count < 16, !out.contains(id) {
            out.append(id)
            parent = records.items[id]?.parent
        }
        return out
    }

    // MARK: - Act

    private func archive(_ items: [String]) throws(AutoArchiveRefusal) {
        guard let store = activeStore() else { throw AutoArchiveRefusal(message: AutoArchiveStrings.needsDocument) }
        do throws(SidebarDocSendRefusal) {
            try store.setArchived(items, archived: true, title: AutoArchiveStrings.undoTitle)
        } catch {
            throw AutoArchiveRefusal(message: error.message)
        }
        ledger.autoArchived.formUnion(items)
        markDirty()
        host.autoArchiveToast(AutoArchiveStrings.archived(items.count)) { [weak self] in self?.restore(items) }
    }

    /// Unarchives `items` (the toast's Undo, Restore in the Archived list).
    public func restore(_ items: [String]) {
        guard let store = activeStore(), !items.isEmpty else { return }
        try? store.setArchived(items, archived: false, title: AutoArchiveStrings.restoreTitle)
        ledger.autoArchived.subtract(items)
        let time = clockNow()
        for item in items {
            if case let .workspace(ref)? = store.records.items[item]?.body { ledger.saw(ref.workspaceID, at: time) }
        }
        markDirty()
    }

    /// The Tidy Up card, as small as it can be (Lawrence 18515, gallery pick T3): "2 idle workspaces",
    /// the names, Archive and an inline "Always" switch; the x is Not Now (a day's snooze). Flipping Always turns
    /// on `workspaces.autoArchive.style` `quiet` and archives these now.
    private func suggest(_ due: [AutoArchivePlanner.Candidate], days: Int) {
        guard card == nil else { return }
        var lines = due.prefix(Self.cardNames).map(\.title)
        if due.count > Self.cardNames { lines.append(AutoArchiveStrings.andMore(due.count - Self.cardNames)) }
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
                let still = Set(plan(.sweep).due.map(\.item))
                try? archive(items.filter(still.contains))
            default:
                ledger.snoozedUntil = clockNow().addingTimeInterval(Self.snooze).timeIntervalSince1970
                markDirty()
                schedulePass(after: .seconds(Self.snooze))
            }
        }
    }

    static let archiveAction = "archive"
    static let alwaysAction = "always"

    // MARK: - Shows

    func noteShown(_ shown: Set<String>) {
        let time = clockNow()
        var back: [String] = []
        for workspace in shown {
            ledger.saw(workspace, at: time)
            // O(shown windows) per switch: the item lookup runs only while something is auto-archived.
            guard !ledger.autoArchived.isEmpty, let item = host.autoArchiveItem(workspace: workspace),
                  ledger.autoArchived.contains(item), activeStore()?.records.isArchived(item: item) == true else { continue }
            back.append(item)
        }
        if !back.isEmpty { restore(back) }
        if !shown.isEmpty { markDirty() }
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
