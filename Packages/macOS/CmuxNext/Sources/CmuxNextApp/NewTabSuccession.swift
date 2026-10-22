import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWakeups

/// Leo 2026-10-13: a new tab appears where it will live. The daemon makes a tab at the end of its
/// pane, and a tab bound elsewhere moves there afterwards (`NewTabSlot`): what a New Tab page
/// turns into takes the page's slot, which closes a frame later, and New Tab to the Right goes
/// right after its tab. Shown as reported, that was a tab growing in at the end and sliding back,
/// beside a page shrinking away. While such a tab is made, its pane's strip shows it in its slot
/// from its first frame, in the page's cell when it replaces one (`TabStripModel.successors`),
/// until the daemon's order says the same. A tab the pane reports before the app knows it is this
/// one (the daemon's answer can trail its report) waits for that, a few milliseconds. A static of
/// the open, not the pane (the godfile limit counts PaneController's extensions).
@MainActor
struct NewTabSuccession {
    /// How long an unanswered open holds back the pane's new tabs.
    static let answerLimit: Duration = .milliseconds(500)
    /// How long the new tab is kept in its slot for the daemon's order to agree (a move's round trip).
    static let orderLimit: Duration = .seconds(2)

    /// By pane model: pane ids repeat across machines.
    private static var active: [ObjectIdentifier: NewTabSuccession] = [:]

    /// The New Tab page the new tab replaces, if it replaces one.
    let page: StripTabID?
    /// The tab the new one goes right after; nil: the first unpinned slot.
    let before: StripTabID?
    /// The pane's daemon tabs when the open started.
    let known: Set<String>
    /// The new tab's surface once known.
    var surface: SurfaceID?
    var deadline: ContinuousClock.Instant
    /// Ends the succession at its deadline: the strip then shows the pane as reported.
    let expiry = DemandTimer(owner: "NewTabSuccession.deadline")
    weak var services: AppServices?
    weak var pane: PaneModel?

    /// Whether a new tab of `pane` is still being placed (tests).
    static func isOpen(in pane: PaneModel) -> Bool { active[ObjectIdentifier(pane)] != nil }

    /// Starts showing what replaces New Tab page `key` in the page's slot. Returns the open, for `made`.
    @discardableResult
    static func begin(replacing key: String, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        guard let index = pane.tabs.firstIndex(where: { $0.id == key }) else { return nil }
        return begin(page: StripTabID(key), after: index > 0 ? pane.tabs[index - 1].id : nil, in: pane, services: services)
    }

    /// Starts showing the pane's next new tab right after `anchor`. Returns the open, for `made`.
    @discardableResult
    static func begin(after anchor: String, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        begin(page: nil, after: anchor, in: pane, services: services)
    }

    /// Starts showing the pane's next new tab first, after its pinned tabs. Returns the open, for `made`.
    @discardableResult
    static func begin(atStartOf pane: PaneModel, services: AppServices) -> DemandTimer? {
        begin(page: nil, after: nil, in: pane, services: services)
    }

    private static func begin(page: StripTabID?, after anchor: String?, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        active[ObjectIdentifier(pane)]?.expiry.cancel()
        // A CLI or script open selects nothing and shows nothing: its tab lands as reported.
        guard ActionRunScope.viewChangeAllowed() else {
            active[ObjectIdentifier(pane)] = nil
            return nil
        }
        let succession = NewTabSuccession(page: page, before: anchor.map { StripTabID($0) }, known: Set(pane.tabs.map(\.id)),
                                          deadline: ContinuousClock.now.advanced(by: answerLimit), services: services, pane: pane)
        active[ObjectIdentifier(pane)] = succession
        succession.expire(after: answerLimit)
        return succession.expiry
    }

    /// The tab `open` (what `begin` returned) makes in `pane` is on `surface`. An open a later one
    /// in the same pane replaced names nothing: its tab lands as reported.
    static func made(_ surface: SurfaceID, in pane: PaneModel, by open: DemandTimer?) {
        guard let open, active[ObjectIdentifier(pane)]?.expiry === open else { return }
        active[ObjectIdentifier(pane)]?.found(surface)
    }

    private mutating func found(_ surface: SurfaceID) {
        self.surface = surface
        deadline = ContinuousClock.now.advanced(by: Self.orderLimit)
        expire(after: Self.orderLimit)
    }

    private func expire(after limit: Duration) {
        guard let pane else { return }
        let timer = expiry, key = ObjectIdentifier(pane)
        timer.schedule(after: limit) { @MainActor [weak services, weak pane] in
            guard Self.active[key]?.expiry === timer else { return }
            Self.active[key] = nil
            if let pane { services?.paneController(for: pane)?.syncStripFromStore() }
        }
    }

    /// `snapshot` as `pane`'s strip shows it while a new tab of it is made. A tab the store made
    /// for a provisional one (Cmd-T's New Tab page shows before the store has its tab) takes the
    /// provisional tab's cell: the store swaps them in one step, so one provisional tab leaving as
    /// one tab arrives is that pair. It was a shrink beside a grow on every Cmd-T.
    static func order(_ snapshot: PaneController.Snapshot, in pane: PaneController) -> PaneController.Snapshot {
        let shown = Set(pane.stripModel.tabs.map(\.id)), listed = Set(snapshot.items.map(\.id))
        let left = shown.filter { ProvisionalTab.isProvisional($0.rawValue) && !listed.contains($0) }
        let arrived = snapshot.items.filter { !shown.contains($0.id) }
        var handed: SurfaceID?
        if left.count == 1, arrived.count == 1, let provisional = left.first {
            pane.stripModel.successors[arrived[0].id] = provisional
            handed = pane.pane.tabs.first { $0.id == arrived[0].id.rawValue }?.surface
            // The selection goes with the cell, in the same apply: a selected stand-in never
            // hands the pane to a neighbor for the frames until its creator hears the reply.
            if pane.stripModel.selectedID == provisional, let handed { pane.pendingSelectSurface = handed }
        }
        guard var succession = active[ObjectIdentifier(pane.pane)] else { return snapshot }
        guard ContinuousClock.now < succession.deadline else {
            active[ObjectIdentifier(pane.pane)] = nil
            return snapshot
        }
        var snapshot = snapshot
        // The store's tab after a provisional one, the one made, else the tab being selected.
        let tabs = pane.pane.tabs.filter { !succession.known.contains($0.id) }
        let made = [handed, succession.surface, pane.pendingSelectSurface].lazy.compactMap { $0 }.first { surface in tabs.contains { $0.surface == surface } }
        guard let made, let tab = tabs.first(where: { $0.surface == made }), let item = snapshot.items.first(where: { $0.id.rawValue == tab.id }) else {
            // Not answered yet: a new daemon tab of this pane waits for the answer naming this one
            // (a reopened tab being selected never does). One the strip already shows stays: hidden,
            // the selection would take it for closed and move to a neighbor (census #7).
            let fresh = Set(tabs.map(\.id)).subtracting(shown.map(\.rawValue)).subtracting(pane.pendingSelectTab.map { [$0] } ?? [])
            snapshot.items.removeAll { fresh.contains($0.id.rawValue) }
            return snapshot
        }
        if succession.surface != made { succession.found(made) }
        var others = snapshot.items.filter { $0.id != item.id && $0.id != succession.page }
        // `NewTabSlot`'s slot: the page's, else right after the anchor's group, never among the pinned tabs.
        var slot = others.prefix { $0.isPinned }.count
        if let before = succession.before, var index = others.firstIndex(where: { $0.id == before }) {
            if succession.page == nil, let group = others[index].groupID {
                while index + 1 < others.count, others[index + 1].groupID == group { index += 1 }
            }
            slot = succession.page == nil ? max(index + 1, slot) : index + 1
        }
        others.insert(item, at: slot)
        if let page = succession.page, listed.contains(page) { pane.stripModel.successors[item.id] = page }
        // Done once the daemon's order agrees (the page closed, the move landed).
        if snapshot.items == others { succession.expiry.cancel() }
        active[ObjectIdentifier(pane.pane)] = snapshot.items == others ? nil : succession
        snapshot.items = others
        return snapshot
    }
}
