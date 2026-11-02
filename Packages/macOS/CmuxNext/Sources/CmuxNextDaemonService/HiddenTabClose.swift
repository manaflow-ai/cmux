public import CmuxNextDaemon

/// Tabs a person's close took out of their strips in the key's turn while the daemon's read decides (SHORTCUT
/// LATENCY SL-3; lead, #31875): a close intent hides them (``DaemonStore/intendClose(_:)``) and nothing is sent, so
/// their terminals stay alive. The close lifts the hide in the turn its own close intent takes them out again (no
/// flash); a running program rolls it back, and the tabs come back at their places.
@MainActor
public struct HiddenTabClose {
    private let transaction: ClientTransactionID
    private let store: DaemonStore
    private let panes: [@MainActor (_ restored: Bool) -> Void]

    /// Hides `surfaces` now. `panes` show the change: called with false at once and when the hide lifts, with true
    /// when it is rolled back (each then selects again what it selected). Nil when none of them is shown.
    public static func hide(_ surfaces: [SurfaceID], in store: DaemonStore, panes: [@MainActor (_ restored: Bool) -> Void]) -> HiddenTabClose? {
        guard let transaction = store.intendClose(surfaces) else { return nil }
        for pane in panes { pane(false) }
        return HiddenTabClose(transaction: transaction, store: store, panes: panes)
    }

    /// The hide ends; the caller's close takes the tabs out again in this same turn.
    public func lift() { store.rejectIntent(transaction) }

    /// The tabs come back at their places, each pane's selection as it was.
    public func restore() {
        lift()
        for pane in panes { pane(true) }
    }
}
