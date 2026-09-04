import SwiftUI

/// The measured visual baseline shared by every Computer Use onboarding state.
///
/// Values use a four-point rhythm where possible. Rounded tiles use the same
/// 7/32 corner-to-side ratio as the shipped helper icon, while the cursor is
/// positioned from its measured path bounds so its *bounding box* (rather than
/// its asymmetric ink centroid) is centered in the icon canvas.
struct ComputerUseOnboardingVisualTokens: Sendable {
    /// The reference token set used by the onboarding views and icon renderer.
    static let reference = Self()

    let gridUnit: CGFloat

    // Expanded presentation (the fixed 600 × 440 onboarding window).
    let expandedWindowSize: CGSize
    let expandedContentHorizontalInset: CGFloat
    let expandedHeroTopInset: CGFloat
    let heroTitleSpacing: CGFloat
    let heroDetailSpacing: CGFloat
    let heroDetailLineSpacing: CGFloat
    let heroPermissionsSpacing: CGFloat
    let expandedFooterMinimumGap: CGFloat
    let expandedFooterBottomInset: CGFloat
    let heroArtworkSize: CGFloat

    // Type hierarchy. Fixed point sizes preserve the compact window's
    // measured baseline; text views add tightening/minimum-scale affordances
    // so longer localized strings stay inside that baseline.
    let titlePointSize: CGFloat
    let bodyPointSize: CGFloat
    let permissionTitlePointSize: CGFloat
    let permissionDetailPointSize: CGFloat
    let actionPointSize: CGFloat
    let companionApplicationPointSize: CGFloat
    let titleMinimumScaleFactor: CGFloat
    let compactTextMinimumScaleFactor: CGFloat

    // Permission cards.
    let permissionCardRowsSpacing: CGFloat
    let permissionCardHeight: CGFloat
    let permissionCardHorizontalInset: CGFloat
    let permissionCardContentSpacing: CGFloat
    let permissionCardTextSpacing: CGFloat
    let permissionCardIconSize: CGFloat
    let permissionActionSize: CGSize

    // Completion presentation.
    let completionMarkSize: CGFloat
    let completionTopInset: CGFloat
    let completionTitleSpacing: CGFloat
    let completionDetailSpacing: CGFloat
    let completionProgressSpacing: CGFloat
    let completionContentHorizontalInset: CGFloat

    // Compact companion presentation.
    let companionSize: CGSize
    let companionHorizontalInset: CGFloat
    let companionVerticalInset: CGFloat
    let companionLeadingColumnWidth: CGFloat
    let companionHeaderHeight: CGFloat
    let companionDragRowHeight: CGFloat
    let companionColumnSpacing: CGFloat
    let companionRowSpacing: CGFloat
    let companionHeaderArrowSize: CGFloat
    let companionDragContentSpacing: CGFloat
    let companionDragHorizontalInset: CGFloat
    let companionHelperIconSize: CGFloat

    // Shared icon geometry. The path bounds are the extrema of the Sky kite's
    // quadratic curves in its 0…12.59 source coordinate space.
    let helperIconCanvasSize: CGSize
    let helperIconCursorPathBounds: CGRect
    let helperIconCursorScale: CGFloat
    let helperIconCursorTranslation: CGPoint
    let helperIconRimWidth: CGFloat
    let tileCornerRadiusRatio: CGFloat

    // The flat chrome colors are kept alongside the geometry so all three
    // presentations use the same brand midpoint and endpoint.
    let brandBlue: Color
    let brandViolet: Color

    init() {
        gridUnit = 4

        expandedWindowSize = CGSize(width: 600, height: 440)
        expandedContentHorizontalInset = 40
        expandedHeroTopInset = 44
        heroTitleSpacing = 16
        heroDetailSpacing = 8
        heroDetailLineSpacing = 4
        heroPermissionsSpacing = 20
        expandedFooterMinimumGap = 12
        expandedFooterBottomInset = 16

        heroArtworkSize = 64

        titlePointSize = 25
        bodyPointSize = 13
        permissionTitlePointSize = 15
        permissionDetailPointSize = 12.5
        actionPointSize = 13
        companionApplicationPointSize = 13
        titleMinimumScaleFactor = 0.8
        compactTextMinimumScaleFactor = 0.72

        permissionCardRowsSpacing = 12
        permissionCardHeight = 72
        permissionCardHorizontalInset = 16
        permissionCardContentSpacing = 12
        permissionCardTextSpacing = 4
        permissionCardIconSize = 38
        permissionActionSize = CGSize(width: 62, height: 26)

        completionMarkSize = 60
        completionTopInset = 108
        completionTitleSpacing = 20
        completionDetailSpacing = 8
        completionProgressSpacing = 28
        completionContentHorizontalInset = 48

        companionSize = CGSize(width: 472, height: 112)
        companionHorizontalInset = 12
        companionVerticalInset = 8
        companionLeadingColumnWidth = 40
        companionHeaderHeight = 48
        companionDragRowHeight = 40
        companionColumnSpacing = 8
        companionRowSpacing = 8
        companionHeaderArrowSize = 32
        companionDragContentSpacing = 8
        companionDragHorizontalInset = 12
        companionHelperIconSize = 26

        helperIconCanvasSize = CGSize(width: 1_024, height: 1_024)
        helperIconCursorPathBounds = CGRect(
            x: 0.4957769,
            y: 0.4957769,
            width: 10.6598503,
            height: 10.6598503
        )
        helperIconCursorScale = 44.8
        helperIconRimWidth = 14
        tileCornerRadiusRatio = 7.0 / 32.0
        helperIconCursorTranslation = CGPoint(
            x: (helperIconCanvasSize.width
                - helperIconCursorPathBounds.width * helperIconCursorScale) / 2
                - helperIconCursorPathBounds.minX * helperIconCursorScale,
            y: (helperIconCanvasSize.height
                - helperIconCursorPathBounds.height * helperIconCursorScale) / 2
                - helperIconCursorPathBounds.minY * helperIconCursorScale
        )

        brandBlue = Color(
            red: 0x2D / 255.0,
            green: 0x8C / 255.0,
            blue: 0xFF / 255.0
        )
        brandViolet = Color(
            red: 0x6C / 255.0,
            green: 0x5C / 255.0,
            blue: 0xFF / 255.0
        )
    }

    /// The hero-sized radius reused by the compact companion container.
    var companionCornerRadius: CGFloat {
        tileCornerRadius(for: heroArtworkSize)
    }

    /// The card radius derived from the same rounded-tile ratio as the icon.
    var permissionCardCornerRadius: CGFloat {
        tileCornerRadius(for: permissionCardHeight)
    }

    /// Returns a rounded-square radius using the helper icon's measured ratio.
    ///
    /// - Parameter side: The side length of the square in points or pixels.
    /// - Returns: The nearest whole-pixel radius, clamped to the square.
    func tileCornerRadius(for side: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        let measuredRadius = (side * tileCornerRadiusRatio).rounded()
        return min(side / 2, max(0, measuredRadius))
    }

    /// The helper tile's corner radius at the source canvas resolution.
    var helperIconCornerRadius: CGFloat {
        tileCornerRadius(for: helperIconCanvasSize.width)
    }

    /// The cursor bounds after the measured translation and scale are applied.
    var helperIconCursorBoundsInCanvas: CGRect {
        CGRect(
            x: helperIconCursorTranslation.x
                + helperIconCursorPathBounds.minX * helperIconCursorScale,
            y: helperIconCursorTranslation.y
                + helperIconCursorPathBounds.minY * helperIconCursorScale,
            width: helperIconCursorPathBounds.width * helperIconCursorScale,
            height: helperIconCursorPathBounds.height * helperIconCursorScale
        )
    }

    /// Whether the transformed cursor bounds are centered within a tolerance.
    ///
    /// - Parameter tolerance: The allowed distance from the canvas midpoint.
    /// - Returns: `true` when both axes fall within `tolerance` points.
    func helperIconCursorIsOpticallyCentered(
        tolerance: CGFloat = 0.5
    ) -> Bool {
        let bounds = helperIconCursorBoundsInCanvas
        let canvas = CGRect(origin: .zero, size: helperIconCanvasSize)
        return abs(bounds.midX - canvas.midX) <= tolerance
            && abs(bounds.midY - canvas.midY) <= tolerance
    }
}
