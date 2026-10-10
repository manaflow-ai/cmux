import CmuxNextDaemon
import CmuxNextSettings

/// Where a new tab the user opens goes (cx-d0d.58). As in Chrome and Edge,
/// Cmd-T and the strip's + append it; `tabs.newTabPosition: afterCurrent`
/// puts it right after the selected tab, and the tab menu's New Tab to the
/// Right right after that tab. The tab is made where it always is (the
/// end), then moves into its slot (`TabMoves.move`, optimistic) as soon as
/// the store lists it. A tab made in another pane (the docked chat's strip)
/// stays where it lands.
@MainActor
enum NewTabSlot {
    /// How long the move waits for the store to list the new tab.
    static let listLimit: Duration = .seconds(10)

    /// The tab a new tab goes right after, nil for the end: `tab` (the
    /// selected or named one) for New Tab to the Right, and for a person's
    /// Cmd-T or + under `afterCurrent`.
    static func anchor(after tab: TabModel?, toRight: Bool, user: Bool, position: NewTabPosition?) -> SurfaceID? {
        toRight || (user && position == .afterCurrent) ? tab?.surface : nil
    }

    /// `then` for a new tab's surface that first moves the tab right after `anchor`.
    static func placing(after anchor: SurfaceID?, services: AppServices,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard let anchor else { return then }
        return { surface in
            then?(surface)
            place(after: anchor, services: services) { services.locateTab(surface: surface) }
        }
    }

    /// Same for a tab named by its id (agent tabs and the New Tab page).
    static func placing(after anchor: SurfaceID?, services: AppServices,
                        then: (@MainActor (String) -> Void)?) -> (@MainActor (String) -> Void)? {
        guard let anchor else { return then }
        return { key in
            then?(key)
            place(after: anchor, services: services) { services.locateTab(key)?.0 }
        }
    }

    /// Moves the tab `find` returns right after `anchor` once the store lists it.
    private static func place(after anchor: SurfaceID, services: AppServices, find: @escaping @MainActor () -> TabModel?) {
        services.registry.track(Task { @MainActor in
            let listed = Task { @MainActor () -> Bool in
                for await found in Observations({ find() != nil }) where found { return true }
                return false
            }
            let bound = Task { @MainActor in
                try? await Task.sleep(for: listLimit)
                listed.cancel()
            }
            let found = await listed.value
            bound.cancel()
            guard found, let tab = find(), let pane = services.locateTab(tab.id)?.1,
                  let index = slot(after: anchor, in: pane), pane.tabs.firstIndex(where: { $0 === tab }) != index else { return nil }
            TabMoves.move(tab, to: pane, index: index, services: services)
            return nil
        })
    }

    /// The final index right after `anchor` in `pane`, with the new tab
    /// already at the end: never among the pinned tabs, and after the
    /// anchor's tab group, which the new tab does not join. Nil when the
    /// anchor is not in `pane`.
    static func slot(after anchor: SurfaceID, in pane: PaneModel) -> Int? {
        guard var index = pane.tabs.firstIndex(where: { $0.surface == anchor }) else { return nil }
        if let group = pane.tabs[index].tabGroup {
            while index + 1 < pane.tabs.count, pane.tabs[index + 1].tabGroup == group { index += 1 }
        }
        return max(index + 1, pane.tabs.prefix { $0.pinned }.count)
    }
}
