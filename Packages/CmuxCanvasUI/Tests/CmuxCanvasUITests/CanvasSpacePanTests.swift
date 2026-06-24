import CoreGraphics
import Testing
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas space pan")
struct CanvasSpacePanTests {
    @Test func dragMovesViewportAsIfGrabbingCanvas() {
        let origin = CanvasRootView.spacePanClipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 1
        )

        #expect(origin.x == 70)
        #expect(origin.y == 240)
    }

    @Test func dragDeltaScalesWithMagnification() {
        let origin = CanvasRootView.spacePanClipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 0.5
        )

        #expect(origin.x == 40)
        #expect(origin.y == 280)
    }
}
