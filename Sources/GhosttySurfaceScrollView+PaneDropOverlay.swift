import AppKit
import Bonsplit

extension GhosttySurfaceScrollView {
    /// Sets the zone SwiftUI forwards, or the zone resolved by the pane drag target.
    func setDropZoneOverlay(zone: DropZone?, fromPaneDrag: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone, fromPaneDrag: fromPaneDrag)
            }
            return
        }
        if fromPaneDrag {
            paneDragDropZone = zone
            paneDragPreviewIsActive = zone != nil
            if zone == nil {
                activeDropZone = nil
                pendingDropZone = nil
                forwardedDropZone = nil
                applyDropZoneOverlay(zone: nil)
                return
            }
        } else {
            forwardedDropZone = zone
        }
        let resolvedZone = paneDragPreviewIsActive ? paneDragDropZone : forwardedDropZone
        applyDropZoneOverlay(zone: resolvedZone)
    }

    /// Removes both overlay sources when the hosted surface receives a new pane identity.
    func clearPaneDropOverlayForContextChange() {
        forwardedDropZone = nil
        paneDragDropZone = nil
        paneDragPreviewIsActive = false
        activeDropZone = nil
        pendingDropZone = nil
        dropZoneOverlayAnimator.hideImmediately()
    }
}
