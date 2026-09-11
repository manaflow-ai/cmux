import Bonsplit
import Foundation

/// Registration identity retained while a Cloud tree drag owns AppKit.
@MainActor
extension CloudTreeOutlineView.Coordinator {
    struct ActiveDrag {
        let id: UUID
        let registration: TabDragTransferRegistration
        let transferRegistry: TabDragTransferRegistry
    }
}
