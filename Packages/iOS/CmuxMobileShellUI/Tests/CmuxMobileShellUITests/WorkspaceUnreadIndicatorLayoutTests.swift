import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

/// The unread badge is leading-aligned in a gutter narrower than itself, so
/// every element laid out after the gutter must reserve the badge's overflow
/// through `WorkspaceUnreadDot.layoutGap`. These tests pin that shared math to
/// the shipped settings for both consumers: the workspace row's color rail and
/// the group header's disclosure chevron (which the badge used to lean on).
@MainActor
@Suite struct WorkspaceUnreadIndicatorLayoutTests {
    /// Where the badge's trailing edge lands, measured from the gutter's
    /// leading edge, for the shipped badge geometry.
    private var shippedBadgeTrailingEdge: CGFloat {
        CGFloat(MobileDisplaySettings.defaultUnreadBadgeDiameter)
            - CGFloat(MobileDisplaySettings.defaultUnreadIndicatorLeftShift)
    }

    private func shippedGap(visualGap: CGFloat) -> CGFloat {
        WorkspaceUnreadDot.layoutGap(
            afterGutterForDiameter: MobileDisplaySettings.defaultUnreadBadgeDiameter,
            leftShift: MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
            visualGap: visualGap
        )
    }

    @Test func groupHeaderChevronClearsBadgeByItsVisualGap() {
        let gap = shippedGap(visualGap: WorkspaceGroupHeaderRow.indicatorChevronVisualGap)
        let chevronLeadingEdge = WorkspaceUnreadDot.gutterWidth + gap
        #expect(
            chevronLeadingEdge - shippedBadgeTrailingEdge
                == WorkspaceGroupHeaderRow.indicatorChevronVisualGap
        )
    }

    @Test func workspaceRowRailKeepsItsVisualGap() {
        let gap = shippedGap(visualGap: WorkspaceRow.unreadDotRailVisualGap)
        let railLeadingEdge = WorkspaceUnreadDot.gutterWidth + gap
        #expect(railLeadingEdge - shippedBadgeTrailingEdge == WorkspaceRow.unreadDotRailVisualGap)
    }

    /// The lab's extremes (small badge, maximum left shift) push the badge
    /// entirely left of the gutter; the reservation clamps at zero instead of
    /// laying out negative width.
    @Test func gapClampsToZeroWhenBadgeShiftsPastTheGutter() {
        let gap = WorkspaceUnreadDot.layoutGap(
            afterGutterForDiameter: MobileDisplaySettings.unreadBadgeDiameterRange.lowerBound,
            leftShift: MobileDisplaySettings.unreadIndicatorLeftShiftRange.upperBound,
            visualGap: WorkspaceGroupHeaderRow.indicatorChevronVisualGap
        )
        #expect(gap == 0)
    }
}
