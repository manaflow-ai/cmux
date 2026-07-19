#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh geometry")
struct WorkspaceListRefreshGeometryTests {
    @Test("uses the fixed refresh presentation dimensions")
    func usesFixedRefreshPresentationDimensions() {
        #expect(WorkspaceListRefreshGeometry.holdHeight == 56)
        #expect(WorkspaceListRefreshGeometry.triggerDistance == 72)
    }

    @Test("measures pull distance from the baseline adjusted inset")
    func measuresPullDistanceFromBaselineAdjustedInset() {
        let geometry = makeGeometry(
            adjustedTop: 54,
            currentTop: 10,
            offsetY: -90
        )

        #expect(geometry.baseAdjustedTop == 54)
        #expect(geometry.pullDistance == 36)
        #expect(geometry.pullProgress == 0.5)
        #expect(!geometry.isArmed)
        #expect(geometry.restingOffsetY == -54)
        #expect(geometry.heldOffsetY == -110)
        #expect(geometry.releasePinHeight == WorkspaceListRefreshGeometry.holdHeight)
        #expect(geometry.collapseTargetOffsetY == -54)
    }

    @Test("subtracts the active refresh inset from the adjusted inset")
    func subtractsActiveRefreshInsetFromAdjustedInset() {
        let geometry = makeGeometry(
            adjustedTop: 110,
            currentTop: 66,
            offsetY: -110
        )

        #expect(geometry.baseAdjustedTop == 54)
        #expect(geometry.pullDistance == WorkspaceListRefreshGeometry.holdHeight)
        #expect(abs(geometry.pullProgress - 7.0 / 9.0) < 0.000_001)
        #expect(!geometry.isArmed)
        #expect(geometry.restingOffsetY == -54)
        #expect(geometry.heldOffsetY == -110)
        #expect(geometry.collapseTargetOffsetY == -54)
    }

    @Test("clamps pull distance at zero below the baseline")
    func clampsPullDistanceAtZeroBelowBaseline() {
        let geometry = makeGeometry(
            adjustedTop: 54,
            currentTop: 10,
            offsetY: 120
        )

        #expect(geometry.pullDistance == 0)
        #expect(geometry.pullProgress == 0)
        #expect(!geometry.isArmed)
    }

    @Test("caps progress and arms at the trigger distance")
    func capsProgressAndArmsAtTriggerDistance() {
        let atTrigger = makeGeometry(
            adjustedTop: 54,
            currentTop: 10,
            offsetY: -126
        )
        let beyondTrigger = makeGeometry(
            adjustedTop: 54,
            currentTop: 10,
            offsetY: -180
        )

        #expect(atTrigger.pullProgress == 1)
        #expect(atTrigger.isArmed)
        #expect(atTrigger.releasePinHeight == WorkspaceListRefreshGeometry.triggerDistance)
        #expect(beyondTrigger.pullProgress == 1)
        #expect(beyondTrigger.isArmed)
        #expect(beyondTrigger.releasePinHeight == 126)
    }

    @Test("preserves a user-scrolled offset when collapsing")
    func preservesUserScrolledOffsetWhenCollapsing() {
        let geometry = makeGeometry(
            adjustedTop: 110,
            currentTop: 66,
            offsetY: 240
        )

        #expect(geometry.collapseTargetOffsetY == 240)
    }

    private func makeGeometry(
        adjustedTop: CGFloat,
        currentTop: CGFloat,
        offsetY: CGFloat
    ) -> WorkspaceListRefreshGeometry {
        WorkspaceListRefreshGeometry(
            baseContentInset: UIEdgeInsets(top: 10, left: 4, bottom: 12, right: 8),
            adjustedContentInset: UIEdgeInsets(
                top: adjustedTop,
                left: 4,
                bottom: 46,
                right: 8
            ),
            currentContentInset: UIEdgeInsets(
                top: currentTop,
                left: 4,
                bottom: 12,
                right: 8
            ),
            contentOffset: CGPoint(x: 17, y: offsetY)
        )
    }
}
#endif
