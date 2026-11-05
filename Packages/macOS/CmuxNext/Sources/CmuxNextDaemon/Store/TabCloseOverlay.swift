import Foundation

/// The overlay of a ``Intent/closeTabs(surfaces:)`` intent: the daemon tabs the person closed
/// are out of the visible records from the input's turn until the daemon's records drop them
/// (tab-spam-race). Before this, a close hid its tabs in the app only, until the command's
/// reply; a reply that came before its `tab-closed` event was applied showed the closed tab
/// again, and Cmd-T / Cmd-W spam flickered tabs back in.
@MainActor struct TabCloseOverlay {
    let store: DaemonStore

    /// Takes every listed daemon tab the records hold out of its pane; nil when none is there.
    /// A provisional tab is never listed (its close cancels its creation, ``CancelledCreation``).
    func apply(_ surfaces: [SurfaceID]) -> IntentUndo? {
        var hidden: [HiddenTab] = []
        for surface in surfaces where !ProvisionalTab.isProvisional(surface: surface) {
            guard let tab = store.tab(surface: surface), let pane = store.index.pane(holding: tab),
                  let index = pane.tabs.firstIndex(where: { $0 === tab }), let removed = pane.removeTab(surface: surface) else { continue }
            store.index.remove(removed)
            hidden.append(HiddenTab(tab: removed, pane: pane.handle, index: index))
        }
        guard !hidden.isEmpty else { return nil }
        store.index.noteTabOrderChanged()
        return .closedTabs(hidden)
    }

    /// Puts the tabs back at their places, last removed first.
    func undo(_ hidden: [HiddenTab]) {
        for entry in hidden.reversed() { CancelledCreation.unhide(.hiddenTab(entry), in: store) }
    }

    /// Whether the confirmed records (the overlay is lifted) still hold a closed tab: the intent
    /// stays, so its settlement and the daemon's `tab-closed` land in one apply.
    func daemonHolds(_ surfaces: [SurfaceID]) -> Bool {
        surfaces.contains { store.tab(surface: $0) != nil }
    }
}

extension DaemonStore {
    /// Closes daemon tabs `surfaces` in the visible state now: a close intent hides them until
    /// the daemon's records drop them. The caller sends the close and then calls
    /// ``noteSettled(_:at:)`` with the event sequence read after the reply,
    /// ``noteSettledAtNextSnapshot(_:)`` when the outcome is unknown, or ``rejectIntent(_:)``
    /// when it failed (the tabs show again: the daemon kept them).
    ///
    /// - Parameter surfaces: The daemon tabs to close; provisional surfaces are ignored.
    /// - Returns: The close's transaction, or nil when none of them is shown.
    public func intendClose(_ surfaces: [SurfaceID]) -> ClientTransactionID? {
        print("DIAGTRACE intendClose \(surfaces.map(\.rawValue)) overlayLifted=\(overlayLifted)")
        let shown = surfaces.filter { !ProvisionalTab.isProvisional(surface: $0) && tab(surface: $0) != nil }
        guard !shown.isEmpty else { return nil }
        let transaction = ClientTransactionID.generate()
        intend(.closeTabs(surfaces: shown), transaction: transaction)
        return transaction
    }
}

extension DaemonStore {
    /// The ids of the daemon tabs whose close is in flight (hidden by a pending close intent).
    public var closingTabIDs: Set<String> {
        intentLog.entries.reduce(into: Set<String>()) { ids, entry in
            if case .closedTabs(let hidden)? = entry.undo { ids.formUnion(hidden.map(\.tab.id)) }
        }
    }

    /// `move-tab`'s final index and the tab's current index in the daemon's order of `pane` for a move of `surface`
    /// to `index` of the visible `pane.tabs`. A close held back from the daemon (``holdTabs(_:)``, `HiddenTabClose`
    /// while its read decides) leaves its tabs out of the visible order but not the daemon's, and its close goes out
    /// after this move: the tab goes right before the visible tab now at `index` (else last), so it no longer lands one
    /// slot early (Leo 2026-11-05, the close/create shuffle: Cmd-T after b, close a, the new tab ended first). A close
    /// already sent reaches the daemon before the move, so its tabs do not count.
    public func daemonMoveIndex(_ index: Int, moving surface: SurfaceID, in pane: PaneModel) -> (final: Int, current: Int?) {
        var order = pane.tabs.map(\.surface)
        let others = order.filter { $0 != surface }
        // Each held close's overlay undone, newest first, as `TabCloseOverlay.undo` would.
        for entry in intentLog.entries.reversed() {
            guard case .closedTabs(let hidden)? = entry.undo else { continue }
            for tab in hidden.reversed() where tab.pane == pane.handle && heldTabIDs.contains(tab.tab.id) { order.insert(tab.tab.surface, at: min(tab.index, order.count)) }
        }
        let full = order.filter { $0 != surface }
        let final = others.dropFirst(index).first.flatMap { full.firstIndex(of: $0) } ?? full.count
        return (final, order.firstIndex(of: surface))
    }
}
