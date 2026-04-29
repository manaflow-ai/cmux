import CoreGraphics
@testable import CMUXWorkspaceSplit
import XCTest

final class WorkspacePaneDropRoutingTests: XCTestCase {
    func testZoneChoosesCenterAwayFromEdges() {
        XCTAssertEqual(
            WorkspacePaneDropRouting.zone(
                for: CGPoint(x: 200, y: 160),
                in: CGSize(width: 400, height: 320)
            ),
            .center
        )
    }

    func testDecisionPreservesTargetAndSourcePaneIds() {
        let targetPane = PaneID()
        let sourcePane = PaneID()

        let decision = WorkspacePaneDropRouting.decision(
            for: CGPoint(x: 12, y: 160),
            in: CGSize(width: 400, height: 320),
            targetPaneId: targetPane,
            sourcePaneId: sourcePane
        )

        XCTAssertEqual(decision.defaultZone, .left)
        XCTAssertEqual(decision.finalZone, .left)
        XCTAssertEqual(decision.targetPaneId, targetPane)
        XCTAssertEqual(decision.sourcePaneId, sourcePane)
        XCTAssertNil(decision.remapReason)
    }

    func testOverlayFrameUsesStableEdgePadding() {
        XCTAssertEqual(
            WorkspacePaneDropRouting.overlayFrame(
                for: .right,
                in: CGSize(width: 400, height: 320)
            ),
            CGRect(x: 200, y: 4, width: 196, height: 312)
        )
    }
}
