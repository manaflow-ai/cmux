import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups

/// Leo 2026-10-13: a new tab appears where it will live. The daemon makes a tab at the end of its pane, and a tab bound
/// elsewhere moves there afterwards (`NewTabSlot`): what a New Tab page turns into takes the page's slot, which closes a
/// frame later, and New Tab to the Right goes right after its tab. Shown as reported, that was a tab growing in at the end
/// and sliding back, beside a page shrinking away. While such a tab is made, its pane's strip shows it in its slot from its
/// first frame, in the page's cell when it replaces one (`TabStripModel.successors`), until the daemon's order says the
/// same. A tab the pane reports before the app knows it is this one (the daemon's answer can trail its report) waits for
/// that, a few milliseconds. Opens overlap (Cmd-T twice, Cmd-T then the +): each keeps its tab in its slot, oldest first
/// (Leo 2026-11-07: no "unexpected openings"; a later open ended the earlier). A static of the open, not the pane (the
/// godfile limit counts PaneController's extensions).
@MainActor
struct NewTabSuccession {
    /// How long an unanswered open holds back the pane's new tabs, and how long its tab is kept in its slot for the daemon's
    /// order to agree (a move's round trip).
    static let answerLimit: Duration = .milliseconds(500), orderLimit: Duration = .seconds(2)

    /// By pane model (pane ids repeat across machines), oldest open first.
    private static var active: [ObjectIdentifier: [NewTabSuccession]] = [:]

    /// The New Tab page the new tab replaces, if it replaces one.
    let page: StripTabID?
    /// The tab the new one goes right after (in its group when `joins`: a duplicate); nil: the first unpinned slot. Re-anchored when it closes first.
    var before: StripTabID?, joins = false
    /// The pane's daemon tabs when the open started, in its order.
    let known: [String]
    /// The new tab (its stand-in, then the daemon's tab) and its surface, once known.
    var claimed: StripTabID?, surface: SurfaceID?
    var deadline: ContinuousClock.Instant
    /// Ends the succession at its deadline: the strip then shows the pane as reported.
    let expiry = DemandTimer(owner: "NewTabSuccession.deadline")
    weak var services: AppServices?
    weak var pane: PaneModel?

    /// Whether a new tab of `pane` is still being placed (tests).
    static func isOpen(in pane: PaneModel) -> Bool { active[ObjectIdentifier(pane)]?.isEmpty == false }

    /// Starts showing what replaces New Tab page `key` in the page's slot. Returns the open, for `made`.
    @discardableResult
    static func begin(replacing key: String, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        guard let index = pane.tabs.firstIndex(where: { $0.id == key }) else { return nil }
        return begin(page: StripTabID(key), after: index > 0 ? pane.tabs[index - 1].id : nil, in: pane, services: services)
    }

    /// Starts showing the pane's next new tab right after `anchor`, or first after its pinned tabs for nil (`joining`: in its group). Returns the open, for `made`.
    @discardableResult
    static func begin(after anchor: String?, joining: Bool = false, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        begin(page: nil, after: anchor, joining: joining, in: pane, services: services)
    }

    private static func begin(page: StripTabID?, after anchor: String?, joining: Bool = false, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        // A CLI or script open selects nothing and shows nothing: its tab lands as reported (opens being placed keep their slots).
        guard ActionRunScope.viewChangeAllowed() else { return nil }
        let succession = NewTabSuccession(page: page, before: anchor.map { StripTabID($0) }, joins: joining, known: pane.tabs.map(\.id),
                                          deadline: ContinuousClock.now.advanced(by: answerLimit), services: services, pane: pane)
        active[ObjectIdentifier(pane), default: []].append(succession)
        succession.expire(after: answerLimit)
        return succession.expiry
    }

    /// The tab `open` (what `begin` returned) makes in `pane` is on `surface`. An open that ended names nothing.
    static func made(_ surface: SurfaceID, in pane: PaneModel, by open: DemandTimer?) {
        guard let open, let index = active[ObjectIdentifier(pane)]?.firstIndex(where: { $0.expiry === open }) else { return }
        active[ObjectIdentifier(pane)]?[index].found(surface, claiming: true)
    }

    private mutating func found(_ surface: SurfaceID, claiming: Bool = false) {
        if claiming, surface != self.surface, !(claimed.map { ProvisionalTab.isProvisional($0.rawValue) } ?? true) { claimed = nil } // its word beats a guess; a stand-in resolves
        self.surface = surface
        deadline = ContinuousClock.now.advanced(by: Self.orderLimit)
        expire(after: Self.orderLimit)
    }

    /// Where `open`'s new tab goes among `others` (the pane's tabs but it) once its anchor closed: after `order`'s re-anchor; nil once the open ended.
    static func rebasedSlot(in pane: PaneModel, by open: DemandTimer?, among others: [TabModel]) -> Int? { active[ObjectIdentifier(pane)]?.first { $0.expiry === open }.map { open in open.before.map { open.resolved($0, in: pane) }.flatMap { id in others.first { $0.id == id.rawValue } }.flatMap { TabGroupWrites.slot(after: $0, in: others) } ?? others.prefix { $0.pinned }.count } }

    /// `id`, or the daemon's tab stand-in `id` became; `resolving` does it for the open's tab and anchor.
    private func resolved(_ id: StripTabID, in pane: PaneModel) -> StripTabID { services?.daemon(for: pane).store.creations.replacement(ofStandIn: id.rawValue, in: pane).map { StripTabID($0.id) } ?? id }
    private func resolving(_ pane: PaneModel) -> Self { var open = self; (open.claimed, open.before) = (claimed.map { resolved($0, in: pane) }, before.map { resolved($0, in: pane) }); return open }

    private func expire(after limit: Duration) {
        guard let pane else { return }
        let timer = expiry, key = ObjectIdentifier(pane)
        timer.schedule(after: limit) { @MainActor [weak services, weak pane] in
            guard let opens = Self.active[key], opens.contains(where: { $0.expiry === timer }) else { return }
            Self.active[key] = opens.count == 1 ? nil : opens.filter { $0.expiry !== timer }
            if let pane { services?.paneController(for: pane)?.syncStripFromStore() }
        }
    }

    /// `snapshot` as `pane`'s strip shows it while a new tab of it is made. A tab the store made for a provisional one (Cmd-T's
    /// New Tab page shows before the store has its tab) takes the provisional tab's cell: the store swaps them in one step, so
    /// one provisional tab leaving as one tab arrives is that pair when that tab is the stand-in's (F1 on #38085). It was a shrink beside a grow on every Cmd-T.
    static func order(_ snapshot: PaneController.Snapshot, in pane: PaneController) -> PaneController.Snapshot {
        let shown = Set(pane.stripModel.tabs.map(\.id)), listed = Set(snapshot.items.map(\.id))
        let left = shown.filter { ProvisionalTab.isProvisional($0.rawValue) && !listed.contains($0) }
        let arrived = snapshot.items.filter { !shown.contains($0.id) }, swapped = arrived.filter { pane.daemon.store.creations.tookAStandInsPlace(tab: $0.id.rawValue, in: pane.pane) }
        var handed: SurfaceID?
        if left.count == 1, arrived.count == 1, let provisional = left.first, pane.daemon.store.creations.handsOver(standIn: provisional.rawValue, to: arrived[0].id.rawValue, in: pane.pane) {
            pane.stripModel.successors[arrived[0].id] = provisional
            handed = pane.pane.tabs.first { $0.id == arrived[0].id.rawValue }?.surface
            // The selection goes with the cell, in the same apply: a selected stand-in never
            // hands the pane to a neighbor for the frames until its creator hears the reply.
            if pane.stripModel.selectedID == provisional, let handed { pane.pendingSelect.surface = handed }
        }
        let key = ObjectIdentifier(pane.pane), now = ContinuousClock.now
        let opens = (active[key] ?? []).filter { now < $0.deadline }.map { $0.resolving(pane.pane) } // stand-ins the store replaced: the daemon's tabs
        var snapshot = snapshot, items = snapshot.items, kept: [NewTabSuccession] = [], claimed = Set(opens.compactMap(\.claimed))
        // Stand-ins swapped in one snapshot (no answer named them yet), in order, with as many tabs the daemon named as a creation's (never one moved in, a script's or a closed stand-in's: F3 on #37799); each stand-in's tab in this pass, for an open placed after it.
        var unpaired = left.count == swapped.count ? swapped.map(\.id).filter { !claimed.contains($0) } : [], became: [StripTabID: StripTabID] = [:]
        for (index, var open) in opens.enumerated() {
            if let leader = open.before.flatMap({ became[$0] }) { open.before = leader }
            // Its own tab, else its surface; the newest also by the store's tab after a provisional one or the tab being selected.
            let newest = index == opens.count - 1, known = Set(open.known), tabs = pane.pane.tabs.filter { !known.contains($0.id) }
            let mine = open.claimed.flatMap { id in tabs.first { $0.id == id.rawValue } ?? open.surface.flatMap { surface in tabs.first { $0.surface == surface } } ?? (left.contains(id) ? unpaired.first.flatMap { next in tabs.first { $0.id == next.rawValue } } : nil) }
            if let mine, unpaired.first?.rawValue == mine.id { unpaired.removeFirst() }
            let guessed = [newest ? handed : nil, open.surface, newest ? pane.pendingSelect.surface : nil].lazy.compactMap { $0 }.compactMap { surface in tabs.first { $0.surface == surface && !claimed.contains(StripTabID($0.id)) } }.first
            guard let tab = mine ?? guessed, let item = items.first(where: { $0.id.rawValue == tab.id }) else {
                // Not answered yet: a new daemon tab of this pane waits for the answer naming this one (a reopened tab being selected never
                // does). One the strip already shows stays (hidden, the selection would move to a neighbor: census #7), as does another open's.
                let fresh = Set(tabs.map(\.id)).subtracting(shown.map(\.rawValue)).subtracting(pane.pendingSelect.tab.map { [$0] } ?? []).subtracting(claimed.map(\.rawValue))
                items.removeAll { fresh.contains($0.id.rawValue) }
                kept.append(open)
                continue
            }
            if let shown = open.claimed { became[shown] = item.id } // a stand-in swapped before the store names it (`resolving`)
            (open.claimed, _) = (item.id, claimed.insert(item.id))
            if open.surface != tab.surface { open.found(tab.surface) }
            var others = items.filter { $0.id != item.id && $0.id != open.page }
            let after = open.before.flatMap { before in others.contains { $0.id == before } ? before : pane.stripModel.anchor(replacing: before, newTab: left.union([item.id]), staying: Set(others.map(\.id)), opened: open.known.map { StripTabID($0) }) } // re-anchored when it closed
            if let before = open.before?.rawValue, !pane.daemon.store.creations.isUnderway(standIn: before), !pane.pane.tabs.contains(where: { $0.id == before }) { open.before = after } // a stand-in under way, or a tab hidden until answered, stays the anchor for the move (`a b 2 1 c`)
            // `NewTabSlot`'s slot: the page's, else right after the anchor's group (a duplicate: in it; re-anchored above when it closed), never among the pinned tabs.
            var slot = others.prefix { $0.isPinned }.count, placed = item
            if let before = after, var index = others.firstIndex(where: { $0.id == before }) {
                if open.joins, let group = others[index].groupID { placed.groupID = group }
                while open.page == nil, !open.joins, let group = others[index].groupID, index + 1 < others.count, others[index + 1].groupID == group { index += 1 }
                slot = open.page == nil ? max(index + 1, slot) : index + 1
            }
            others.insert(placed, at: slot)
            if let page = open.page, listed.contains(page) { pane.stripModel.successors[item.id] = page }
            if items == others { open.expiry.cancel() } else { kept.append(open) } // done once the daemon's order agrees (the page closed, the move landed)
            items = others
        }
        active[key] = kept.isEmpty ? nil : kept
        snapshot.items = items
        return snapshot
    }
}
