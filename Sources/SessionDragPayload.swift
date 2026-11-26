import Bonsplit
import Foundation

/// Registers a Vault row as the same live capability used by Bonsplit tab drags.
struct SessionDragPayload {
    let entry: SessionEntry
    let dragID: UUID

    /// Creates a lease in the pane registry shared by every eligible target.
    @MainActor
    func register(
        with registry: TabDragTransferRegistry
    ) -> TabDragTransferRegistration? {
        registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(
                id: TabID(uuid: dragID),
                title: entry.displayTitle,
                icon: "terminal.fill",
                kind: "terminal"
            ),
            // Vault rows are external sources, so this identity intentionally
            // never names a live pane. The tab id is already unique per drag.
            sourcePaneId: PaneID(id: dragID)
        ))
    }
}
