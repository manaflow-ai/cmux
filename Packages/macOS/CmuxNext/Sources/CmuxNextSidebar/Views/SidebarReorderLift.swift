import AppKit
import CmuxNextDesign
import QuartzCore

/// The lifted card of an in-place reorder drag (R77), shared by the
/// workspace list and the item sections: it follows the pointer on one
/// axis, then settles into the slot the display already holds for it.
@MainActor enum SidebarReorderLift {
    /// Puts the card on `frame` in `host`, lifted.
    static func lift(_ content: NSView, count: Int = 1, frame: NSRect, in host: NSView) -> DragLiftView {
        let lift = DragLiftView(content: content, count: count)
        lift.frame = frame
        host.addSubview(lift)
        lift.setLifted(true, animated: true)
        return lift
    }

    /// Moves the card to `y` (its top), at once, kept half inside `visible`.
    static func follow(_ lift: DragLiftView, top y: CGFloat, visible: NSRect) {
        var frame = lift.frame
        frame.origin.y = min(max(y, visible.minY - frame.height / 2), visible.maxY - frame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.frame = frame
        CATransaction.commit()
    }

    /// Flies the card to `destination` (its slot) and removes it.
    static func land(_ lift: DragLiftView, at destination: NSRect?, completion: @escaping () -> Void) {
        lift.setLifted(false, animated: true)
        Motion.animate(.settle, {
            lift.animator().frame = destination ?? lift.frame
        }, completion: {
            lift.removeFromSuperview()
            completion()
        })
    }
}
