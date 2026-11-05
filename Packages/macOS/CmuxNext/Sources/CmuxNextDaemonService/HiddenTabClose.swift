public import CmuxNextDaemon

/// Tabs a person's close took out of their strips in the key's turn while the daemon's read decides (SHORTCUT
/// LATENCY SL-3; lead, #31875): a close intent hides them (``DaemonStore/intendClose(_:)``) and nothing is sent, so
/// their terminals stay alive. The close lifts the hide in the turn its own close intent takes them out again (no
/// flash); a running program rolls it back, and the tabs come back at their places.
@MainActor
public struct HiddenTabClose {
    private let transaction: ClientTransactionID
    private let store: DaemonStore
    private let ids: Set<String>
    private let panes: [@MainActor (_ restored: Bool) -> Void]
    private let lifted: [@MainActor () -> Void]

    /// Hides `surfaces` now; the store still lists them for its gone-tab watchers (``DaemonStore/holdTabs(_:)``), so
    /// their views and pages stay. `panes` show the change: called with false at once, with true when the hide is rolled
    /// back (each then selects again what it selected). `lifted` run as the hide lifts for the close (``lift()``), before
    /// the close's own intent: a pane the hide emptied hands its shown close on to it. Nil when none of them is shown.
    public static func hide(_ surfaces: [SurfaceID], in store: DaemonStore, panes: [@MainActor (_ restored: Bool) -> Void],
                            lifted: [@MainActor () -> Void] = []) -> HiddenTabClose? {
        // Held first: the watchers that wake for the hide's tab list change must still see them listed.
        let ids = Set(surfaces.compactMap { store.tab(surface: $0)?.id })
        print("DIAGTRACE hide \(ids.sorted())")
        store.holdTabs(ids)
        guard let transaction = store.intendClose(surfaces) else { store.releaseHeldTabs(ids); return nil }
        for pane in panes { pane(false) }
        return HiddenTabClose(transaction: transaction, store: store, ids: ids, panes: panes, lifted: lifted)
    }

    /// The hide ends; the caller's close takes the tabs out again in this same turn.
    public func lift() {
        print("DIAGTRACE lift \(ids.sorted())")
        end()
        for lift in lifted { lift() }
    }

    /// The tabs come back at their places, each pane's selection as it was.
    public func restore() {
        print("DIAGTRACE restore \(ids.sorted())")
        end()
        for pane in panes { pane(true) }
    }

    private func end() {
        store.releaseHeldTabs(ids)
        store.rejectIntent(transaction)
    }
}
