import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The conversation list slides in and out with the Chats button (``HomeSidebarSlide``) instead
/// of appearing or vanishing in one frame. While it runs, this view places both columns itself on
/// each frame of the window's FrameScheduler: the list at its own width, partly off the page's
/// leading edge, and the chat filling the rest. At the end the split's own layout takes over at
/// the same place.
extension HomeSidebarSplitView {
    /// The sidebar spring for showing (`open`) or folding the list, nil when it should not slide:
    /// off screen, sidebar motion off (Reduce Motion, calm mode, the animation switches, a live
    /// resize), or a list that will not show (one folded for a lone conversation stays folded).
    func slideSpring(open: Bool) -> SpringParameters? {
        guard window != nil, bounds.width > 0, !foldsLoneConversation else { return nil }
        let policy = Motion.sidebar.policy(in: window)
        return policy.animatesMovement ? policy.spring(open ? .appear : .disappear) : nil
    }

    /// Slides the list from `shownNow` points showing to open (its width) or folded (0).
    func slideList(from shownNow: CGFloat, open: Bool, spring: SpringParameters) {
        if var running = slide {
            // Turned around mid-slide: the same width, from where it is, with the speed it has.
            running.retarget(open ? slideWidth : 0, parameters: spring)
            slide = running
        } else {
            slideWidth = open ? wantedWidth : max(sidebarWidth, 1)
            slide = HomeSidebarSlide(from: shownNow, to: open ? slideWidth : 0, parameters: spring)
        }
        list.isHidden = false
        // The list's part past the leading edge is not drawn over the window's other views.
        clipsToBounds = true
        placeSlideFrame()
        slideClient.activate()
    }

    /// One frame of the slide; false once it landed.
    func slideFrame(_ tick: FrameTick) -> Bool {
        guard var running = slide else { return false }
        running.advance(tick.frameElapsed)
        slide = running
        if running.isSettled {
            endSlide()
            return false
        }
        placeSlideFrame()
        return true
    }

    /// Both columns where the slide is now.
    func placeSlideFrame() {
        guard let slide else { return }
        let width = slideWidth
        let reveal = max(0, min(width, slide.reveal))
        let height = bounds.height
        // The divider comes in with the list, so the chat's edge never jumps by its width.
        let divider = width > 0 ? dividerThickness * reveal / width : 0
        list.frame = NSRect(x: (reveal - width).rounded(), y: 0, width: width, height: height)
        let x = (reveal + divider).rounded()
        chatColumn.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height)
        needsDisplay = true
    }

    /// The slide ends (it landed, the view left its window, or a change that does not slide cut it
    /// short): the split's own layout places the columns for the list's choice now.
    func endSlide() {
        slideClient.deactivate()
        guard slide != nil else { return }
        slide = nil
        clipsToBounds = false
        placed = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}
