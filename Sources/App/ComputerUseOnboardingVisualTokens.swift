import CoreGraphics

/// Measured artwork geometry shared by the Computer Use onboarding surfaces.
///
/// The cursor is intentionally asymmetric, so its tight path bounds—not its
/// ink centroid or the enclosing frame—define the centered placement.
struct ComputerUseOnboardingVisualTokens: Sendable {
    /// The immutable measured baseline used by the onboarding renderer.
    static let reference = Self()

    /// The source canvas used by the helper icon and its checked-in asset.
    let helperIconCanvasSize: CGSize
    /// The tight bounds of the cursor path before scale and translation.
    let helperIconCursorPathBounds: CGRect
    /// The scale from cursor path units to canvas pixels.
    let helperIconCursorScale: CGFloat
    /// Translation that centers the transformed tight bounds in the canvas.
    let helperIconCursorTranslation: CGPoint
    /// Width of the helper icon's inner rim stroke.
    let helperIconRimWidth: CGFloat
    /// Rounded-tile corner radius as a fraction of the tile side.
    let tileCornerRadiusRatio: CGFloat

    init() {
        helperIconCanvasSize = CGSize(width: 1_024, height: 1_024)
        helperIconCursorPathBounds = ComputerUseCursorArtwork.path().boundingBoxOfPath
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
    }

    /// The rounded-tile radius at the requested side length.
    ///
    /// - Parameter side: The side length in points or pixels.
    /// - Returns: A radius clamped to the tile's valid range.
    func tileCornerRadius(for side: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        let radius = (side * tileCornerRadiusRatio).rounded()
        return min(side / 2, max(0, radius))
    }

    /// The helper icon's rounded plate radius at source-canvas resolution.
    var helperIconCornerRadius: CGFloat {
        tileCornerRadius(for: helperIconCanvasSize.width)
    }

    /// The transformed cursor bounds in helper-icon canvas coordinates.
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

    /// Whether the transformed tight cursor bounds are centered in the canvas.
    ///
    /// - Parameter tolerance: The permitted midpoint distance on either axis.
    /// - Returns: `true` when both midpoint distances are within `tolerance`.
    func helperIconCursorIsOpticallyCentered(tolerance: CGFloat = 0.5) -> Bool {
        let bounds = helperIconCursorBoundsInCanvas
        let canvas = CGRect(origin: .zero, size: helperIconCanvasSize)
        return abs(bounds.midX - canvas.midX) <= tolerance
            && abs(bounds.midY - canvas.midY) <= tolerance
    }
}
