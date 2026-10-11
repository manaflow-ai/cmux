import AppKit
import CmuxNextDesign
import QuartzCore

/// The lifted card of an in-place reorder drag (R77), shared by the
/// workspace list and the item sections: it follows the pointer (on one
/// axis in a list, on both in a flowed section), then settles into the slot the display already holds for it.
@MainActor enum SidebarReorderLift {
    /// Puts the card on `frame` in `host`, lifted.
    static func lift(_ content: NSView, count: Int = 1, frame: NSRect, in host: NSView) -> DragLiftView {
        let lift = DragLiftView(content: content, count: count)
        lift.frame = frame
        host.addSubview(lift)
        lift.setLifted(true, animated: true)
        return lift
    }

    /// Moves the card's origin to `origin`, at once, kept half inside
    /// `visible` on both axes: a flowed section (tiles, a grid, one line)
    /// reorders sideways as well as up and down.
    static func follow(_ lift: DragLiftView, origin: CGPoint, visible: NSRect) {
        var frame = lift.frame
        frame.origin.x = min(max(origin.x, visible.minX - frame.width / 2), visible.maxX - frame.width / 2)
        frame.origin.y = min(max(origin.y, visible.minY - frame.height / 2), visible.maxY - frame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.frame = frame
        CATransaction.commit()
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
        Motion.animate(.settle, in: lift, {
            lift.animator().frame = destination ?? lift.frame
        }, completion: {
            lift.removeFromSuperview()
            completion()
        })
    }
}
