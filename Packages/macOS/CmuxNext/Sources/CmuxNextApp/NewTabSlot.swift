import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups

/// Where a new tab the user opens goes (cx-d0d.58). Cmd-T and the other new-tab keys follow `tabs.newTabPosition`: right
/// after the selected tab by default (Lawrence 2026-10-20), else at the end or the start (after the pinned tabs); the strip's
/// + `tabs.newTabButtonPosition` (the end). New Tab After Current Tab, at Start, at End and the tab menu's New Tab to the Right
/// name their place whatever the setting says. The tab is made at the end, then moves into its slot (`TabMoves.move`,
/// optimistic) once its pane lists it. A tab made in another pane (the docked chat's strip) stays where it lands. What a
/// New Tab page turns into takes the page's slot.
@MainActor
enum NewTabSlot {
    /// How long the move waits for the pane to list the new tab.
    static let listLimit: Duration = .seconds(10)

    /// A slot other than the end (the end is nil: the daemon appends).
    enum Target: Equatable {
        /// Right after this tab, after its tab group.
        case after(TabModel)
        /// First after the pinned tabs of the pane this tab is in.
        case start(TabModel)

        /// The tab that names the pane.
        var anchor: TabModel { switch self { case .after(let tab), .start(let tab): tab } }

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) { case (.after(let a), .after(let b)), (.start(let a), .start(let b)): return a === b; default: return false }
        }
    }

    /// Where a new tab goes, nil for the end. `explicit` (the position actions, New Tab to the Right) wins for anyone;
    /// otherwise a person's Cmd-T or + follows `setting` (unset is ``NewTabPosition/fallback``) and a script's `tab new`
    /// appends. `current` is the selected or named tab, `pane` the pane's tabs (for the start with no current tab).
    static func target(current: TabModel?, pane: [TabModel], explicit: NewTabPosition?, user: Bool, setting: NewTabPosition?) -> Target? {
        switch explicit ?? (user ? setting ?? NewTabPosition.fallback : .end) {
        case .end: nil
        case .afterCurrent: current.map(Target.after)
        case .start: (current ?? pane.first).map(Target.start)
        }
    }

    /// `then` for a new tab's surface that first moves the tab right after `anchor`.
    static func placing(after anchor: TabModel?, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        placing(anchor.map(Target.after), services: services, then: then)
    }

    /// Same for a tab named by its id (agent tabs and the New Tab page).
    static func placing(after anchor: TabModel?, services: AppServices,
                        then: (@MainActor (String) -> Void)?) -> (@MainActor (String) -> Void)? {
        placing(anchor.map(Target.after), services: services, then: then)
    }

    /// `then` for a new tab's surface that first moves the tab into `target`'s slot.
    static func placing(_ target: Target?, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard let target else { return then }
        let pane = home(of: target.anchor, services)
        let open = pane.flatMap { begin(target, in: $0, services: services) }, turn = reserve(pane, services: services) // shown in its slot at once
        return { [weak pane] surface in
            if let pane { NewTabSuccession.made(surface, in: pane, by: open) }
            then?(surface)
            place(in: { home(of: target.anchor, services) ?? pane }, turn: turn, services: services, find: { $0.tabs.first { $0.surface == surface } }) { slot(for: target, in: $0, pane: pane, open: open, services: services) }
        }
    }

    /// Same for a tab named by its id (agent tabs and the New Tab page).
    static func placing(_ target: Target?, services: AppServices,
                        then: (@MainActor (String) -> Void)?) -> (@MainActor (String) -> Void)? {
        guard let target else { return then }
        let pane = home(of: target.anchor, services)
        let open = pane.flatMap { begin(target, in: $0, services: services) }, turn = reserve(pane, services: services) // shown in its slot at once
        return { [weak pane] key in
            then?(key)
            place(in: { home(of: target.anchor, services) ?? pane }, turn: turn, services: services, find: { pane in pane.tabs.first { $0.id == key || $0.snapshot.tabResourceID?.rawValue == key } }) {
                slot(for: target, in: $0, pane: pane, open: open, services: services)
            }
        }
    }

    @discardableResult
    private static func begin(_ target: Target, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        switch target {
        case .after(let anchor): NewTabSuccession.begin(after: anchor.id, in: pane, services: services)
        case .start: NewTabSuccession.begin(after: nil, in: pane, services: services)
        }
    }

    /// `then` for the terminal or browser a New Tab page turns into: it takes the page's slot, so a page opened after the
    /// current tab stays there. The page's left neighbour is read now, as the page closes meanwhile.
    static func placing(replacing page: String, onMachine machineID: String, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard let located = services.locateTab(page, onMachine: machineID), case let (tab, pane) = located, let index = pane.tabs.firstIndex(where: { $0 === tab }) else { return then }
        // Shown in the page's slot from its first frame, whatever the daemon reports meanwhile.
        let open = NewTabSuccession.begin(replacing: page, in: pane, services: services)
        let then: @MainActor (SurfaceID) -> Void = { surface in
            NewTabSuccession.made(surface, in: pane, by: open)
            then?(surface)
        }
        guard index + 1 < pane.tabs.count else { return then } // the last tab: the new one appends beside it
        let before = index > 0 ? pane.tabs[index - 1] : nil, turn = reserve(pane, services: services)
        return { surface in
            then(surface)
            place(in: { [weak pane] in pane }, turn: turn, services: services, find: { $0.tabs.first { $0.surface == surface } }) { [weak pane] others in
                guard let before else { return others.prefix { $0.pinned }.count }
                return others.firstIndex { $0 === before }.map { $0 + 1 } ?? pane.flatMap { NewTabSuccession.rebasedSlot(in: $0, by: open, among: others) }
            }
        }
    }

    /// The pane `tab` is in, on any machine (surface ids are per daemon, so a new tab is looked for in this pane only).
    private static func home(of tab: TabModel, _ services: AppServices) -> PaneModel? { services.locateTab(model: tab)?.1 }

    /// `pane`'s next new tab's move, its turn taken at the press: moves go in press order (Ctrl-` then Cmd-T: `a b 2 1 c`); an unanswered one passes within the strip's hold.
    private static func reserve(_ pane: PaneModel?, services: AppServices) -> WorkTurn<ActionWorkFailure?>? { pane.flatMap { services.paneController(for: $0) }?.placements.next(limit: NewTabSuccession.orderLimit, owner: "NewTabSlot.answer", passing: nil) }

    /// Moves the tab `find` returns from `pane` to the final index `index` gives (from the pane's other tabs) once the pane
    /// lists it, and once the pane's previous new tab moved (`turn`): a burst's second Cmd-T goes right after the first new tab,
    /// which sat at the end until its own move, so a slot read before that kept the second there (`a b 1 c 2`).
    private static func place(in pane: @escaping @MainActor () -> PaneModel?, turn: WorkTurn<ActionWorkFailure?>?, services: AppServices,
                              find: @escaping @MainActor (PaneModel) -> TabModel?, index: @escaping @MainActor ([TabModel]) -> Int?) {
        let locate = { @MainActor () -> (TabModel, PaneModel)? in pane().flatMap { pane in find(pane).map { ($0, pane) } } }, earlier = turn?.earlier
        let placement: ActionWork = Task { @MainActor in
            let listed = Task { @MainActor () -> Bool in
                for await found in ObservationStream({ locate() != nil }) where found { return true }
                return false
            }
            let bound = DemandTimer(owner: "NewTabSlot.listed")
            bound.schedule(after: listLimit) { @MainActor in listed.cancel() }
            let found = await listed.value
            bound.cancel()
            _ = await earlier?.value // its own list wait, then its move's reply
            guard found, let located = locate(), case let (tab, pane) = located, let final = index(pane.tabs.filter { $0 !== tab }),
                  pane.tabs.firstIndex(where: { $0 === tab }) != final else { return nil }
            await withCheckedContinuation { landed in TabMoves.move(tab, to: pane, index: final, services: services) { _ in landed.resume() } }
            return nil
        }
        turn?.fill(placement)
        services.registry.track(placement)
    }

    /// The final index for `target` among `others` (the pane's tabs but the new one); an after-anchor that was a stand-in
    /// (Cmd-T on a new tab not answered yet) is the daemon's tab it became; when it left, where `pane`'s `open` re-anchored
    /// the tab (``NewTabSuccession/rebasedSlot(in:by:among:)``), else nil. The start is right after the pinned tabs.
    static func slot(for target: Target, in others: [TabModel], pane: PaneModel? = nil, open: DemandTimer? = nil, services: AppServices? = nil) -> Int? {
        switch target {
        // The open's live anchor first (re-anchored, after an earlier open's tab: Ctrl-` then Cmd-T), then the one it began with.
        case .after(let anchor): pane.flatMap { NewTabSuccession.rebasedSlot(in: $0, by: open, among: others) } ?? others.newTabSlot(after: anchor)
            ?? pane.flatMap { pane in services?.daemon(for: pane).store.creations.replacement(ofStandIn: anchor.id, in: pane).flatMap { others.newTabSlot(after: $0) } }
        case .start: others.prefix { $0.pinned }.count
        }
    }
}
