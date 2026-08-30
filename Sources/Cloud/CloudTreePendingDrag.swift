import AppKit
import Bonsplit
import Foundation

/// Provisional Cloud drag registration retained until AppKit promotes or drops it.
@MainActor
extension CloudTreeOutlineView.Coordinator {
    final class PendingDrag {
        let dragID: UUID
        let registration: TabDragTransferRegistration
        let transferRegistry: TabDragTransferRegistry
        weak var sourceView: NSOutlineView?

        init(
            dragID: UUID,
            registration: TabDragTransferRegistration,
            transferRegistry: TabDragTransferRegistry,
            sourceView: NSOutlineView
        ) {
            self.dragID = dragID
            self.registration = registration
            self.transferRegistry = transferRegistry
            self.sourceView = sourceView
        }
    }
}
