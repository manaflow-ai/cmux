/// Where a pending tab move put its tab, named by the tabs beside it.
///
/// A move's intent holds an index (``Intent/moveTab(surface:toPane:index:)``). The store undoes its pending intents
/// before each daemon apply and each settlement, and applies them again after (`DaemonStore.withOverlayLifted`). The
/// pane's list can have another length then: a tab that a pending close hid is back (its hide ended, or the daemon
/// refused the close), a stand-in left. The same index is then another place. A new tab that moved right after `b`
/// while a close of `a` was hidden showed before `b` when the hide ended (`a N b c`, then `N b c`). Decision of
/// 2026-11-16: that order is a fault. So the log keeps the move's place by its neighbours, read one time at the
/// move's first apply (``PendingIntent/movePlace``), and each later apply takes the index from them.
///
/// Decision of 2026-11-17: the store's place is the place that the daemon's own move gives, where the store can
/// know it. The command to the daemon has an index that counts from the left of the daemon's list
/// (`DaemonStore.daemonMoveIndex`), so on that list the tab lands directly after its left neighbour. So the two
/// neighbours are read in the daemon's order (`DaemonStore.daemonOrder`: the visible tabs and the tabs of each close
/// that is held back from the daemon) at the command's index, and a later apply puts the tab directly after `after`.
/// That is the daemon's order when a held close is rolled back, and when the daemon refuses a sent close of a tab
/// right of the place.
///
/// The command to the daemon does not have this type's rule: it keeps the index, not the neighbours. In two cases
/// the store's order and the daemon's are not the same until the move's answer settles (the move's event alone does
/// not heal it: `IntentOverlay.restore` applies the waiting move again), and then the daemon's order shows:
/// - the daemon refuses a sent close of a tab left of the place. The command did not count that tab, so the daemon's
///   move puts the moved tab one slot left of its place (`AMoveMadeWhileACloseIsHiddenKeepsItsSlotTests`, the row of
///   the refusal);
/// - the move of the left neighbour is refused: by the daemon, or by the store at a request that passed its
///   deadline or lost its connection (`TabMovePlaceTests`, the limit row, with who reaches it).
struct TabMovePlace: Equatable {
    /// The tab that the moved tab stands directly before in the daemon's order; nil: it is the pane's last tab.
    let before: SurfaceID?
    /// The tab that it stands directly after in the daemon's order; nil: it is the pane's first tab.
    let after: SurfaceID?

    /// The place that a tab move's apply gives its tab, read before the apply. Nil for each other intent, and when
    /// the apply finds no target pane or no tab.
    @MainActor init?(of intent: Intent, in store: DaemonStore) {
        guard case .moveTab(let surface, let toPane, let index) = intent, let target = store.panesByHandle[toPane],
              store.pane(containing: surface) != nil else { return nil }
        let order = store.daemonOrder(of: target).filter { $0 != surface }
        let slot = store.daemonMoveIndex(max(index, 0), moving: surface, in: target).final
        before = order[checked: slot]
        after = slot > 0 ? order[checked: slot - 1] : nil
    }

    /// The tab move `intent` with the index that puts its tab at this place among the target pane's tabs now:
    /// directly after `after` (first, when the tab is the first one); when that tab is not in the pane's list (a
    /// close hides it, or it left), directly before `before` (last, when the tab is the last one). `intent` as it is
    /// when both tabs are not in the list, and for each other intent: its own index is then all that is known.
    @MainActor func resolved(_ intent: Intent, in store: DaemonStore) -> Intent {
        guard case .moveTab(let surface, let toPane, _) = intent, let target = store.panesByHandle[toPane] else { return intent }
        let others = target.tabs.map(\.surface).filter { $0 != surface }
        guard let after else { return .moveTab(surface: surface, toPane: toPane, index: 0) }
        if let index = others.firstIndex(of: after) { return .moveTab(surface: surface, toPane: toPane, index: index + 1) }
        guard let before else { return .moveTab(surface: surface, toPane: toPane, index: others.count) }
        guard let index = others.firstIndex(of: before) else { return intent }
        return .moveTab(surface: surface, toPane: toPane, index: index)
    }
}
