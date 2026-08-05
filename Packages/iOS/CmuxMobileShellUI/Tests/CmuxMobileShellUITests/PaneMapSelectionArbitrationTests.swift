import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneMapSelectionArbitrationTests {
    @Test func scrollAndDragMovementDoNotResolveAsPaneSelection() {
        var arbitration = PaneMapSelectionArbitration()

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        arbitration.touchMoved(to: CGPoint(x: 32, y: 10))
        let movementResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 32, y: 10))
        #expect(!movementResolvedAsTap)

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        arbitration.dragSessionDidBegin()
        let dragResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 10, y: 10))
        #expect(!dragResolvedAsTap)

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        let stationaryTouchResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 11, y: 11))
        #expect(stationaryTouchResolvedAsTap)
    }
}
