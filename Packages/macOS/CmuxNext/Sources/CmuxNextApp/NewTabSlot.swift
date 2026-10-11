import CmuxNextDaemon
import CmuxNextSettings
import Observation

/// Where a new tab the user opens goes (cx-d0d.58). As in Chrome and Edge,
/// Cmd-T and the strip's + append it; `tabs.newTabPosition: afterCurrent`
/// puts it right after the selected tab, and the tab menu's New Tab to the
/// Right right after that tab. The tab is made where it always is (the
/// end), then moves into its slot (`TabMoves.move`, optimistic) as soon as
/// the anchor's pane lists it. A tab made in another pane (the docked chat's
/// strip) stays where it lands. What a New Tab page turns into takes the
/// page's slot.
@MainActor
enum NewTabSlot {
    /// How long the move waits for the pane to list the new tab.
    static let listLimit: Duration = .seconds(10)

    /// The tab a new tab goes right after, nil for the end: `tab` (the
    /// selected or named one) for New Tab to the Right, and for a person's
    /// Cmd-T or + under `afterCurrent`.
    static func anchor(after tab: TabModel?, toRight: Bool, user: Bool, position: NewTabPosition?) -> TabModel? {
        toRight || (user && position == .afterCurrent) ? tab : nil
    }

    /// `then` for a new tab's surface that first moves the tab right after `anchor`.
    static func placing(after anchor: TabModel?, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard let anchor else { return then }
        return { surface in
            then?(surface)
            place(in: { home(of: anchor, services) }, services: services, find: { $0.tabs.first { $0.surface == surface } }) { slot(after: anchor, in: $0) }
        }
    }

    /// Same for a tab named by its id (agent tabs and the New Tab page).
    static func placing(after anchor: TabModel?, services: AppServices,
                        then: (@MainActor (String) -> Void)?) -> (@MainActor (String) -> Void)? {
        guard let anchor else { return then }
        return { key in
            then?(key)
            place(in: { home(of: anchor, services) }, services: services, find: { pane in pane.tabs.first { $0.id == key || $0.snapshot.tabResourceID?.rawValue == key } }) {
                slot(after: anchor, in: $0)
            }
        }
    }

    /// `then` for the terminal or browser a New Tab page turns into: it takes
    /// the page's slot, so a page opened after the current tab stays there.
    /// The page's left neighbour is read now, as the page closes meanwhile.
    static func placing(replacing page: String, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard let located = services.locateTab(page), case let (tab, pane) = located, let index = pane.tabs.firstIndex(where: { $0 === tab }),
              index + 1 < pane.tabs.count else { return then } // the last tab: the new one appends beside it
        let before = index > 0 ? pane.tabs[index - 1] : nil
        return { surface in
            then?(surface)
            place(in: { [weak pane] in pane }, services: services, find: { $0.tabs.first { $0.surface == surface } }) { others in
                guard let before else { return others.prefix { $0.pinned }.count }
                return others.firstIndex { $0 === before }.map { $0 + 1 }
            }
        }
    }

    /// The pane `tab` is in, on any machine (surface ids are per daemon, so
    /// a new tab is looked for in this pane only).
    private static func home(of tab: TabModel, _ services: AppServices) -> PaneModel? {
        services.machines.allWorkspaces.lazy.flatMap(\.0.screens).flatMap(\.panes).first { $0.tabs.contains { $0 === tab } }
    }

    /// Moves the tab `find` returns from `pane` to the final index `index`
    /// gives (from the pane's other tabs) once the pane lists it.
    private static func place(in pane: @escaping @MainActor () -> PaneModel?, services: AppServices,
                              find: @escaping @MainActor (PaneModel) -> TabModel?, index: @escaping @MainActor ([TabModel]) -> Int?) {
        let locate = { @MainActor () -> (TabModel, PaneModel)? in pane().flatMap { pane in find(pane).map { ($0, pane) } } }
        services.registry.track(Task { @MainActor in
            let listed = Task { @MainActor () -> Bool in
                for await found in Observations({ locate() != nil }) where found { return true }
                return false
            }
            let bound = Task { @MainActor in
                try? await Task.sleep(for: listLimit)
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
