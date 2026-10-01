import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextBridge

/// Dogfood nxdog13: "when i drag a tab, my mouse's relative position on the
/// tab should never change". While the ghost floats, the point the user
/// grabbed stays under the pointer through the card unfold (tab -> preview
/// card), the drop-target shrink (scale 0.9) and pointer motion, at every
/// frame of those animations.
struct TabDragGrabPointTests {
    let tabSize = CGSize(width: 180, height: 28)
    let cardSize = CGSize(width: 264, height: 210)
    let inset: CGFloat = 6
    /// 40 pt into the tab, 9 pt up from its bottom edge.
    let grab = CGPoint(x: 40, y: 9)

    func layout(_ motion: TabDragGhostMotion) -> TabDragGhostLayout {
        TabDragGhostLayout(motion: motion, cardSize: cardSize, inset: inset, grabOffset: grab, tabSize: tabSize)
    }

    /// Where the grabbed point of the tab image is on screen this frame.
    func grabbedPointOnScreen(_ motion: TabDragGhostMotion) -> CGPoint {
        let layout = layout(motion)
        let fx = grab.x / tabSize.width, fy = grab.y / tabSize.height
        return layout.onScreen(CGPoint(x: layout.tab.minX + fx * layout.tab.width, y: layout.tab.minY + fy * layout.tab.height))
    }

    func expectUnderPointer(_ motion: TabDragGhostMotion, _ pointer: CGPoint, _ label: String) {
        let point = grabbedPointOnScreen(motion)
        #expect(abs(point.x - pointer.x) < 0.01 && abs(point.y - pointer.y) < 0.01, "\(label): \(point) != \(pointer)")
    }

    @Test func theGrabbedPointStaysUnderThePointerWhileTheCardUnfoldsAndShrinks() {
        let pointer = CGPoint(x: 900, y: 600)
        let floating = TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize)
        var motion = TabDragGhostMotion(rect: floating, cardness: 0)
        expectUnderPointer(motion, pointer, "start")
        // Over a drop zone: the card unfolds and shrinks to 0.9 at once.
        motion.setTarget(floating, cardness: 1, scale: 0.9, jump: true)
        var frames = 0
        var sawMidAnimation = false
        while motion.step(1.0 / 120.0), frames < 600 {
            frames += 1
            let l = layout(motion)
            if l.cardness > 0.3, l.cardness < 0.7, l.scale < 0.98 { sawMidAnimation = true }
            expectUnderPointer(motion, pointer, "frame \(frames)")
        }
        #expect(sawMidAnimation)
        #expect(layout(motion).scale == 0.9)
        expectUnderPointer(motion, pointer, "end")
    }

    @Test func thePointerMovingDuringTheAnimationKeepsTheGrabbedPoint() {
        var pointer = CGPoint(x: 400, y: 300)
        var motion = TabDragGhostMotion(rect: TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize), cardness: 0)
        motion.setTarget(TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize), cardness: 1, scale: 0.9, jump: true)
        for frame in 1...60 {
            pointer.x += 7
            pointer.y -= 3
            motion.setTarget(TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize), cardness: 1, scale: 0.9,
                             jump: false)
            _ = motion.step(1.0 / 120.0)
            expectUnderPointer(motion, pointer, "frame \(frame)")
        }
        // Leaving the drop zone: back to full size, still the same point.
        motion.setTarget(TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize), cardness: 1, scale: 1, jump: true)
        while motion.step(1.0 / 120.0) { expectUnderPointer(motion, pointer, "grow back") }
    }

    /// The hand-off: the ghost starts on the tab's slot and settles with the
    /// grabbed point under the pointer, then stays there.
    @Test func theGhostLeavesTheSlotAndLocksOntoTheGrabbedPoint() {
        let slot = CGRect(x: 300, y: 870, width: tabSize.width, height: tabSize.height)
        let pointer = CGPoint(x: slot.minX + grab.x, y: slot.minY + grab.y - 28)
        var motion = TabDragGhostMotion(rect: slot, cardness: 0)
        motion.setTarget(TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grab, tabSize: tabSize), cardness: 1, jump: true)
        #expect(layout(motion).tab == slot)
        var frames = 0
        while motion.step(1.0 / 120.0), frames < 600 { frames += 1 }
        expectUnderPointer(motion, pointer, "settled")
    }
}
