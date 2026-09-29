import AppKit

extension WindowBrowserSlotView {
    func setPortalDragDropZone(_ zone: DropZone?) {
        portalDragDropZone = zone
        if zone == nil {
            // A pane exit must not leave the old target visible while AppKit
            // begins routing the next pane's drag update.
            forwardedDropZone = nil
            dropZoneOverlayAnimator.hideImmediately()
            return
        }
        applyResolvedDropZoneOverlay()
    }

    /// Removes both overlay sources when the slot receives a new pane identity.
    func clearPortalDragOverlayForContextChange() {
        forwardedDropZone = nil
        portalDragDropZone = nil
        dropZoneOverlayAnimator.hideImmediately()
    }
}
