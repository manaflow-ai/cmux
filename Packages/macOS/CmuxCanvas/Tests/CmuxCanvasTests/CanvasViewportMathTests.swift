import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasViewportMathTests {
    private let math = CanvasViewportMath()
    private let viewportSize = CanvasSize(width: 800, height: 600)

    @Test func visibleTargetKeepsOrigin() {
        let origin = math.originToReveal(
            CanvasRect(x: 100, y: 100, width: 200, height: 200),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: 0, y: 0))
    }

    @Test func visibleTargetInsideMarginKeepsOrigin() {
        // Fully on screen but closer to the edges than the margin: focus
        // moves between visible panes must not pan.
        let origin = math.originToReveal(
            CanvasRect(x: 4, y: 590 - 200, width: 790, height: 200),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: 0, y: 0))
    }

    @Test func visibleAxisStaysPutWhileCutOffAxisScrolls() {
        let origin = math.originToReveal(
            CanvasRect(x: 790, y: 100, width: 100, height: 200),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: 914 - 800, y: 0))
    }

    @Test func partlyVisibleTargetScrollsInWithMargin() {
        let origin = math.originToReveal(
            CanvasRect(x: -50, y: -20, width: 200, height: 100),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: -74, y: -44))
    }

    @Test func targetThatFitsOnlyWithoutMarginEndsUpFullyVisible() {
        // 780 wide in an 800 viewport: the 24 pt margin cannot fit on both
        // sides, so the margin shrinks and the far edge stays on screen.
        let origin = math.originToReveal(
            CanvasRect(x: 780, y: 100, width: 780, height: 200),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: 1560 - 800, y: 0))
    }

    @Test func targetBeyondRightBottomScrollsMinimally() {
        let origin = math.originToReveal(
            CanvasRect(x: 900, y: 700, width: 200, height: 100),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        // Right edge 1100 + margin must equal viewport right edge.
        #expect(origin == CanvasPoint(x: 1124 - 800, y: 824 - 600))
    }

    @Test func targetBeyondLeftTopScrollsToItsOrigin() {
        let origin = math.originToReveal(
            CanvasRect(x: -500, y: -300, width: 100, height: 100),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: -524, y: -324))
    }

    @Test func oversizedTargetAlignsTopLeft() {
        let origin = math.originToReveal(
            CanvasRect(x: 100, y: 50, width: 2000, height: 3000),
            viewportOrigin: CanvasPoint(x: 0, y: 0),
            viewportSize: viewportSize,
            margin: 24
        )
        #expect(origin == CanvasPoint(x: 76, y: 26))
    }

    @Test func fitMagnificationClampsToRange() {
        let content = CanvasRect(x: 0, y: 0, width: 8000, height: 600)
        let fit = math.magnificationToFit(
            content,
            in: viewportSize,
            padding: 40,
            range: 0.25...1.0
        )
        #expect(fit == 0.25)

        let small = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        let fitSmall = math.magnificationToFit(
            small,
            in: viewportSize,
            padding: 40,
            range: 0.25...1.0
        )
        #expect(fitSmall == 1.0)
    }

    @Test func fitMagnificationExactFit() {
        let content = CanvasRect(x: 0, y: 0, width: 1520, height: 600)
        let fit = math.magnificationToFit(
            content,
            in: viewportSize,
            padding: 40,
            range: 0.1...1.0
        )
        #expect(fit == 0.5)
    }

    @Test func degenerateContentReturnsSafeMagnification() {
        let fit = math.magnificationToFit(
            CanvasRect(x: 0, y: 0, width: 0, height: 0),
            in: viewportSize,
            padding: 0,
            range: 0.25...4.0
        )
        #expect(fit == 1.0)
    }
}
