import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups

/// Where a new tab the user opens goes (cx-d0d.58). Cmd-T and the strip's
/// + follow `tabs.newTabPosition`: right after the selected tab by default
/// (Lawrence 2026-10-20), else at the end or the start (after the pinned
/// tabs). New Tab After Current Tab, at Start, at End and the tab menu's
/// New Tab to the Right name their place whatever the setting says. The
/// tab is made where it always is (the end), then moves into its slot
/// (`TabMoves.move`, optimistic) as soon as its pane lists it. A tab made in
/// another pane (the docked chat's strip) stays where it lands. What a New
/// Tab page turns into takes the page's slot.
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
        var anchor: TabModel {
            switch self { case .after(let tab), .start(let tab): tab }
        }

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case (.after(let a), .after(let b)), (.start(let a), .start(let b)): a === b
            default: false
            }
        }
    }

    /// Where a new tab goes, nil for the end. `explicit` (the position actions, New Tab to the
    /// Right) wins for anyone; otherwise a person's Cmd-T or + follows `setting` (unset is
    /// ``NewTabPosition/fallback``) and a script's `tab new` appends. `current` is the selected or
    /// named tab, `pane` the pane's tabs (for the start with no current tab).
    static func target(current: TabModel?, pane: [TabModel], explicit: NewTabPosition?, user: Bool,
                       setting: NewTabPosition?) -> Target? {
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
        let open = pane.flatMap { begin(target, in: $0, services: services) } // shown in its slot at once
        return { surface in
            if let pane { NewTabSuccession.made(surface, in: pane, by: open) }
            then?(surface)
            place(in: { home(of: target.anchor, services) }, services: services, find: { $0.tabs.first { $0.surface == surface } }) { slot(for: target, in: $0) }
        }
    }

    /// Same for a tab named by its id (agent tabs and the New Tab page).
    static func placing(_ target: Target?, services: AppServices,
                        then: (@MainActor (String) -> Void)?) -> (@MainActor (String) -> Void)? {
        guard let target else { return then }
        if let pane = home(of: target.anchor, services) { begin(target, in: pane, services: services) } // shown in its slot at once
        return { key in
            then?(key)
            place(in: { home(of: target.anchor, services) }, services: services, find: { pane in pane.tabs.first { $0.id == key || $0.snapshot.tabResourceID?.rawValue == key } }) {
                slot(for: target, in: $0)
            }
        }
    }

    @discardableResult
    private static func begin(_ target: Target, in pane: PaneModel, services: AppServices) -> DemandTimer? {
        switch target {
        case .after(let anchor): NewTabSuccession.begin(after: anchor.id, in: pane, services: services)
        case .start: NewTabSuccession.begin(atStartOf: pane, services: services)
        }
    }

    /// `then` for the terminal or browser a New Tab page turns into: it takes
    /// the page's slot, so a page opened after the current tab stays there.
    /// The page's left neighbour is read now, as the page closes meanwhile.
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
        let before = index > 0 ? pane.tabs[index - 1] : nil
        return { surface in
            then(surface)
            place(in: { [weak pane] in pane }, services: services, find: { $0.tabs.first { $0.surface == surface } }) { others in
                guard let before else { return others.prefix { $0.pinned }.count }
                return others.firstIndex { $0 === before }.map { $0 + 1 }
            }
        }
    }

    /// The pane `tab` is in, on any machine (surface ids are per daemon, so
    /// a new tab is looked for in this pane only).
    private static func home(of tab: TabModel, _ services: AppServices) -> PaneModel? {
        services.locateTab(model: tab)?.1
    }

    /// Moves the tab `find` returns from `pane` to the final index `index`
    /// gives (from the pane's other tabs) once the pane lists it.
    private static func place(in pane: @escaping @MainActor () -> PaneModel?, services: AppServices,
                              find: @escaping @MainActor (PaneModel) -> TabModel?, index: @escaping @MainActor ([TabModel]) -> Int?) {
        let locate = { @MainActor () -> (TabModel, PaneModel)? in pane().flatMap { pane in find(pane).map { ($0, pane) } } }
        services.registry.track(Task { @MainActor in
            let listed = Task { @MainActor () -> Bool in
                for await found in ObservationStream({ locate() != nil }) where found { return true }
                return false
            }
            let bound = DemandTimer(owner: "NewTabSlot.listed")
            bound.schedule(after: listLimit) { @MainActor in
                listed.cancel()
            }
            let found = await listed.value
            bound.cancel()
            guard found, let located = locate(), case let (tab, pane) = located, let final = index(pane.tabs.filter { $0 !== tab }),
                  pane.tabs.firstIndex(where: { $0 === tab }) != final else { return nil }
            TabMoves.move(tab, to: pane, index: final, services: services)
            return nil
        })
    }

    /// The final index for `target` among `others` (the pane's tabs but the new one); nil when
    /// an after-anchor left. The start is right after the pinned tabs.
    static func slot(for target: Target, in others: [TabModel]) -> Int? {
        switch target {
        case .after(let anchor): slot(after: anchor, in: others)
        case .start: others.prefix { $0.pinned }.count
        }
    }

    /// The final index right after `anchor` among `others` (the pane's tabs
    /// but the new one): never among the pinned tabs, and after the anchor's
    /// tab group, which the new tab does not join. Nil when the anchor left.
    static func slot(after anchor: TabModel, in others: [TabModel]) -> Int? {
        guard var index = others.firstIndex(where: { $0 === anchor }) else { return nil }
        if let group = others[index].tabGroup {
            while index + 1 < others.count, others[index + 1].tabGroup == group { index += 1 }
        }
        return max(index + 1, others.prefix { $0.pinned }.count)
    }
}
