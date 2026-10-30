import AppKit

/// The live resize drag. It moves the width constraint directly on every
/// pointer event, so it never goes through the width animation: a drag is the
/// person's own pacing, and an animation would lag behind the pointer.
extension SidebarContainerView {
    func handleDrag(_ phase: SidebarResizeHandle.Phase) {
        switch phase {
        case .began:
            liveStartWidth = model.width
        case let .changed(dx):
            guard !model.isHidden else { return }
            // A right sidebar widens as its leading edge moves left.
            let proposed = liveStartWidth + (side == .left ? dx : -dx)
            if proposed < Self.hideThreshold {
                // Hide outright and come back at the width the drag began at.
                handle.endDrag()
                model.width = liveStartWidth
                model.presentation = .hidden
            } else {
                model.width = proposed
                panelWidth.constant = model.width
                targetWidth = model.width
                widthConstraint.constant = model.width
            }
        case .ended:
            break
        }
    }
}
