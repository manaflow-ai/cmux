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
        lift.setFrameOrigin(frame.origin) // the position only: a running morph's additive springs keep their shape
        CATransaction.commit()
    }

    /// Moves the card to `y` (its top), at once, kept half inside `visible`.
    static func follow(_ lift: DragLiftView, top y: CGFloat, visible: NSRect) {
        var frame = lift.frame
        frame.origin.y = min(max(y, visible.minY - frame.height / 2), visible.maxY - frame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.setFrameOrigin(frame.origin)
        CATransaction.commit()
    }

    /// Settles the card into `destination` (its slot) on the drag's one
    /// spring: position, size, corner shape and shadow together, from what
    /// is on screen (DESIGN "Drag feel" 6). A second call retargets the
    /// landing (the model's slot moved, a refusal sends it back) with no
    /// jump; only the last call's `completion` runs. The caller removes the card.
    static func land(_ lift: DragLiftView, at destination: NSRect?, completion: @escaping @MainActor () -> Void) {
        lift.landings &+= 1
        let landing = lift.landings
        // A window with no screen never advances an animation: the card lands at once.
        guard Motion.canAnimate(in: lift) else {
            Motion.withoutAnimation { lift.frame = destination ?? lift.frame }
            lift.setLifted(false, animated: false)
            return completion()
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { // main-proof: CA runs transaction completions on the main thread
                guard lift.landings == landing else { return }
                completion()
            }
        }
        lift.setLifted(false, animated: true)
        lift.morph(to: destination ?? lift.frame)
        CATransaction.commit()
    }
}
