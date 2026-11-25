import AppKit
@testable import CmuxNextDesign
import Testing

/// AppKit screen coordinates increase upward. An offset viewport also exercises a window
/// that does not begin at the screen origin.
@Suite struct PointerMenuPlacementTests {
    let viewport = CGRect(x: 100, y: 80, width: 800, height: 600)

    private func place(x: CGFloat = 240, y: CGFloat, height: CGFloat = 240) -> (frame: CGRect, side: PopupPlacement.Side) {
        PopupPlacement.frame(anchor: CGRect(x: x, y: y, width: 0, height: 0),
                             size: CGSize(width: 180, height: height), preferred: .below,
                             screen: viewport, gap: 0, margin: 0)
    }

    @Test func opensDownWhenTheWholeMenuFitsExactly() {
        let placed = place(y: 320)
        #expect(placed.side == .below)
        #expect(placed.frame == CGRect(x: 240, y: 80, width: 180, height: 240))
    }

    @Test func opensUpAndLeftAtTheBottomRightPointer() {
        let placed = place(x: 870, y: 100)
        #expect(placed.side == .above)
        #expect(placed.frame == CGRect(x: 690, y: 100, width: 180, height: 240))
    }

    @Test func slidesTowardTheRoomierSideWhenNeitherFits() {
        let down = place(y: 400, height: 440)
        #expect(down.side == .below)
        #expect(down.frame == CGRect(x: 240, y: 80, width: 180, height: 440))
        let up = place(y: 360, height: 440)
        #expect(up.side == .above)
        #expect(up.frame == CGRect(x: 240, y: 240, width: 180, height: 440))
    }

    @Test func confinesNativeTrackingToTheFittingSideOrTheWholeWindow() {
        func confinement(at y: CGFloat, height: CGFloat) -> CGRect {
            PopupPlacement.pointerConfinement(at: CGPoint(x: 240, y: y), size: CGSize(width: 180, height: height),
                                              viewport: viewport)
        }
        #expect(confinement(at: 400, height: 240) == CGRect(x: 100, y: 80, width: 800, height: 320))
        #expect(confinement(at: 100, height: 240) == CGRect(x: 100, y: 100, width: 800, height: 580))
        #expect(confinement(at: 360, height: 440) == viewport)
    }

    @Test func onlyAMenuTallerThanTheWindowLosesHeight() {
        for height: CGFloat in [viewport.height, viewport.height + 100] {
            let placed = place(y: viewport.midY, height: height)
            #expect(placed.frame.minY == viewport.minY)
            #expect(placed.frame.height == viewport.height)
        }
    }
}
