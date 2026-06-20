import CoreGraphics
import Testing
@testable import CmuxSidebar

/// Pins the sidebar resizer hit-band geometry against the production
/// `SidebarResizeInteraction` constants (6 sidebar-side / 4 content-side) so the
/// lifted policy stays byte-faithful to the app's former
/// `ContentView.dividerBandContains` and `SidebarResizeInteraction.Edge.hitRange`.
@Suite struct SidebarResizerBandPolicyTests {
    /// Production composition mirroring `ContentView.bandPolicy`.
    private let policy = SidebarResizerBandPolicy(
        sidebarSideHitWidth: 6,
        contentSideHitWidth: 4
    )

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func totalHitWidthSumsBothSides() {
        #expect(policy.totalHitWidth == 10)
    }

    @Test func leadingHitRangeStraddlesDivider() {
        // dividerX 200 - sidebarSideHitWidth 6 = 194; +10 total = 204.
        #expect(policy.hitRange(for: .leading, dividerX: 200) == 194...204)
    }

    @Test func trailingHitRangeStraddlesDivider() {
        // dividerX 800 - contentSideHitWidth 4 = 796; +10 total = 806.
        #expect(policy.hitRange(for: .trailing, dividerX: 800) == 796...806)
    }

    @Test func bandContainsPointInLeadingBand() {
        #expect(
            policy.bandContains(
                point: CGPoint(x: 198, y: 400),
                contentBounds: bounds,
                leftDividerVisible: true,
                leftDividerX: 200,
                rightDividerVisible: true,
                rightDividerX: 780
            )
        )
    }

    @Test func bandContainsPointInTrailingBand() {
        #expect(
            policy.bandContains(
                point: CGPoint(x: 778, y: 400),
                contentBounds: bounds,
                leftDividerVisible: true,
                leftDividerX: 200,
                rightDividerVisible: true,
                rightDividerX: 780
            )
        )
    }

    @Test func bandMissesPointBetweenDividers() {
        #expect(
            !policy.bandContains(
                point: CGPoint(x: 500, y: 400),
                contentBounds: bounds,
                leftDividerVisible: true,
                leftDividerX: 200,
                rightDividerVisible: true,
                rightDividerX: 780
            )
        )
    }

    @Test func hiddenLeftDividerContributesNoBand() {
        #expect(
            !policy.bandContains(
                point: CGPoint(x: 198, y: 400),
                contentBounds: bounds,
                leftDividerVisible: false,
                leftDividerX: 200,
                rightDividerVisible: true,
                rightDividerX: 780
            )
        )
    }

    @Test func hiddenRightDividerContributesNoBand() {
        #expect(
            !policy.bandContains(
                point: CGPoint(x: 778, y: 400),
                contentBounds: bounds,
                leftDividerVisible: true,
                leftDividerX: 200,
                rightDividerVisible: false,
                rightDividerX: 780
            )
        )
    }

    @Test func pointAboveContentBoundsMissesBand() {
        #expect(
            !policy.bandContains(
                point: CGPoint(x: 198, y: 900),
                contentBounds: bounds,
                leftDividerVisible: true,
                leftDividerX: 200,
                rightDividerVisible: true,
                rightDividerX: 780
            )
        )
    }
}
