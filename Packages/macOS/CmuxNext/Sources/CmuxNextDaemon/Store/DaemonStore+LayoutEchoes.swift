import Foundation

extension DaemonStore {
    /// Notes a drag's daemon `transaction` before its command is sent; the
    /// `.ended` (or cancelled) drag lays its held echo over its screen.
    /// Returns `transaction`, so the caller sends it on.
    @discardableResult
    public func layoutGestureTransaction(_ transaction: UInt64, ended: Bool) -> UInt64 {
        let id = ClientTransactionID(rawValue: String(transaction))
        guard ended else {
            layoutEchoes.live.insert(id)
            return transaction
        }
        layoutEchoes.live.remove(id)
        let due = layoutEchoes.heldByScreen.filter { $0.value.transaction == id }
        for screen in due.keys { layoutEchoes.heldByScreen[screen] = nil }
        let current = due.filter { $0.value.barrier == snapshotBarrier && $0.value.epoch == connectionEpoch }
        guard !current.isEmpty else { return transaction }
        withOverlayLifted(writer: "layout echo") {
            for (handle, held) in current {
                // A pane that came or went since: its own layout-changed brings the layout.
                guard let screen = screen(handle), Self.placesPanes(of: screen, held.layout) else { continue }
                screen.applyLayout(held.layout)
            }
        }
        return transaction
    }

    /// Applies one `layout-changed` that carries its layout: the echo of a
    /// live drag of this app is held, any other patches its screen. A
    /// layout whose panes differ from the screen's (a structural change the
    /// pane deltas have not brought yet, or missed) needs a snapshot.
    func applyLayoutChange(screen handle: ScreenID, layout: ScreenLayoutDelta, transaction: ClientTransactionID?) -> Followup {
        // A focus that moved inside a stack (the same panes, another active
        // one) changes `focused_at` and the active screen too, which only
        // the tree carries.
        guard let screen = screen(handle), Self.placesPanes(of: screen, layout),
              layout.activePane == screen.defaultPane || Set(screen.layout.paneIDs) != Set(layout.layout.paneIDs) else {
            layoutEchoes.heldByScreen[handle] = nil
            return .resync
        }
        if let transaction, layoutEchoes.live.contains(transaction) {
            layoutEchoes.heldByScreen[handle] = .init(transaction: transaction, layout: layout, barrier: snapshotBarrier, epoch: connectionEpoch)
            return .none
        }
        layoutEchoes.heldByScreen[handle] = nil
        screen.applyLayout(layout)
        return .none
    }

    /// The layout places exactly the screen's panes.
    static func placesPanes(of screen: ScreenModel, _ layout: ScreenLayoutDelta) -> Bool {
        Set(layout.layout.paneIDs) == Set(screen.panes.map(\.handle))
    }
}
