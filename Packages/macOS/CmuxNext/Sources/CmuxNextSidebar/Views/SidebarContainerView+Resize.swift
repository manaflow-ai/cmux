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
                panelWidth.constant = model.width + paneReach
                targetWidth = model.width
                widthConstraint.constant = model.width
                setClipReach(paneReach, collapsed: false, animated: false)
            }
        case .ended:
            break
        }
    }

    /// A shown scroller of the sidebar (the list's, a band's, the Priority view's) takes a press at
    /// `point` (the handle's superview's coordinates). The band's inner points lie over the list's
    /// scroller, and a press on its knob scrolls (Lawrence msg 18056). Only reachable while the
    /// handle is mounted beside this view, where that space is also this view's superview's.
    func scrollerTakesPress(at point: CGPoint) -> Bool {
        guard let superview, handle.superview === superview else { return false }
        return hitTest(point) is NSScroller
    }
}
