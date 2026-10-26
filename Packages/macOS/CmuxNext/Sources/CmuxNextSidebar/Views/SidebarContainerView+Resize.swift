import AppKit
public import CmuxNextWakeups

/// The live resize drag. It moves the width constraint directly on every
/// drag the handle delivers (each event, or once per frame with
/// `resizeFrameInput`), so it never goes through the width animation: a drag
/// is the person's own pacing, and an animation would lag behind the pointer.
extension SidebarContainerView {
    /// The windows' frame-aligned input (feature `pointerFrameDrags`): a resize drag moves the
    /// width at most once per frame. Nil: each drag event moves it at once.
    public var resizeFrameInput: FrameInputCoalescers? {
        get { handle.frameInput }
        set { handle.frameInput = newValue }
    }

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
