/// Where a pending tab move put its tab, named by the tabs beside it.
///
/// A move's intent holds an index (``Intent/moveTab(surface:toPane:index:)``). The store undoes its pending intents
/// before each daemon apply and each settlement, and applies them again after (`DaemonStore.withOverlayLifted`). The
/// pane's list can have another length then: a tab that a pending close hid is back (its hide ended, or the daemon
/// refused the close), a stand-in left. The same index is then another place. A new tab that moved right after `b`
/// while a close of `a` was hidden showed before `b` when the hide ended (`a N b c`, then `N b c`). Decision of
/// 2026-11-16: that order is a fault. So the log keeps the move's place by its neighbours, read one time after the
/// move's first apply (``PendingIntent/movePlace``), and each later apply takes the index from them.
///
/// The command to the daemon has the same rule (`DaemonStore.daemonMoveIndex`: right before the visible tab now at
/// the index, else last). This type is the store's own copy of the move, which kept the index.
struct TabMovePlace: Equatable {
    /// The tab that the moved tab stood directly before; nil: it was the pane's last tab.
    let before: SurfaceID?
    /// The tab that it stood directly after; nil: it was the pane's first tab.
    let after: SurfaceID?

    /// The place that a tab move's apply gave its tab. Nil for each other intent, and when the target pane does not
    /// hold the tab (the apply found no tab or no pane).
    @MainActor init?(of intent: Intent, in store: DaemonStore) {
        guard case .moveTab(let surface, let toPane, _) = intent, let tabs = store.panesByHandle[toPane]?.tabs,
              let at = tabs.firstIndex(where: { $0.surface == surface }) else { return nil }
        before = tabs[checked: at + 1]?.surface
        after = at > 0 ? tabs[checked: at - 1]?.surface : nil
    }

    /// The tab move `intent` with the index that puts its tab at this place among the target pane's tabs now:
    /// directly before `before`; when that tab left the pane, directly after `after` (first, when the tab was the
    /// first one); last, when the tab was the last one. `intent` as it is when both tabs left the pane, and for each
    /// other intent: its own index is then all that is known.
    @MainActor func resolved(_ intent: Intent, in store: DaemonStore) -> Intent {
        guard case .moveTab(let surface, let toPane, _) = intent, let target = store.panesByHandle[toPane] else { return intent }
        let others = target.tabs.map(\.surface).filter { $0 != surface }
        guard let before else { return .moveTab(surface: surface, toPane: toPane, index: others.count) }
        if let index = others.firstIndex(of: before) { return .moveTab(surface: surface, toPane: toPane, index: index) }
        guard let after else { return .moveTab(surface: surface, toPane: toPane, index: 0) }
        guard let index = others.firstIndex(of: after) else { return intent }
        return .moveTab(surface: surface, toPane: toPane, index: index + 1)
    }
}
