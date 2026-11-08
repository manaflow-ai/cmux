import AppKit
import Bonsplit
import Foundation

/// Immutable cleanup identity captured when AppKit promotes a file-preview writer.
@MainActor
struct FilePreviewNativeDragOwnership {
    let dragID: UUID
    let filePreviewData: Data
    let fileURL: String
    let transferRegistration: TabDragTransferRegistration?
    let transferRegistry: TabDragTransferRegistry?

    /// Revokes process-local routing without touching any pasteboard.
    ///
    /// A provisional writer has no native session-owned pasteboard yet. Its
    /// materialized bytes may remain cached by AppKit, but resolver lookups are
    /// fenced by these registries and therefore cannot route a later drop.
    func revokeRouting() {
        if let transferRegistration {
            transferRegistry?.end(transferRegistration)
        }
        FilePreviewDragRegistry.shared.discard(id: dragID)
    }

    /// Revokes only this drag's registrations and residual representations.
    func finish(from pasteboard: NSPasteboard) {
        transferRegistration?.clearResidualCapability(from: pasteboard)
        if let transferRegistration {
            transferRegistry?.end(transferRegistration)
        }
        let cleaner = DragPasteboardCapabilityCleaner()
        cleaner.remove(
            type: .fileURL,
            capabilityValue: fileURL,
            from: pasteboard,
            requiring: DragOverlayRoutingPolicy.filePreviewTransferType,
            markerData: filePreviewData
        )
        cleaner.remove(
            type: DragOverlayRoutingPolicy.filePreviewTransferType,
            capabilityData: filePreviewData,
            from: pasteboard
        )
        FilePreviewDragRegistry.shared.discard(id: dragID)
    }
}
