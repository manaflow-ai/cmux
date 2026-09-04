public import CoreGraphics

/// Stores the measured Computer Use artwork tokens shared by every renderer.
///
/// The cursor is intentionally asymmetric, so placement always uses its tight
/// path bounds rather than an ink centroid or an enclosing frame with padding.
nonisolated public struct ComputerUseOnboardingVisualTokens: Sendable {
    /// The immutable shipped baseline used by cmux.
    public static let reference = Self()

    /// The source canvas used by the helper icon and checked-in asset.
    public let helperIconCanvasSize: CGSize
    /// The tight source bounds of the cursor path.
    public let helperIconCursorPathBounds: CGRect
    /// The scale from cursor path units to canvas pixels.
    public let helperIconCursorScale: CGFloat
    /// The translation that centers the transformed tight bounds.
    public let helperIconCursorTranslation: CGPoint
    /// The width of the helper icon's inner rim stroke.
    public let helperIconRimWidth: CGFloat
    /// The rounded-tile corner radius as a fraction of the tile side.
    public let tileCornerRadiusRatio: CGFloat

    /// Creates a token set from the canonical cursor artwork.
    public init(
        helperIconCanvasSize: CGSize = ComputerUseCursorArtwork.defaultCanvasSize,
        helperIconCursorScale: CGFloat = ComputerUseCursorArtwork.defaultScale,
        helperIconRimWidth: CGFloat = ComputerUseCursorArtwork.defaultRimWidth,
        tileCornerRadiusRatio: CGFloat = ComputerUseCursorArtwork.tileCornerRadiusRatio
    ) {
        let artwork = ComputerUseCursorArtwork()
        let pathBounds = artwork.pathBounds()
        self.helperIconCanvasSize = helperIconCanvasSize
        self.helperIconCursorPathBounds = pathBounds
        self.helperIconCursorScale = helperIconCursorScale
        self.helperIconRimWidth = helperIconRimWidth
        self.tileCornerRadiusRatio = tileCornerRadiusRatio
        self.helperIconCursorTranslation = artwork.centeredTranslation(
            canvasSize: helperIconCanvasSize,
            scale: helperIconCursorScale
        )
    }

    /// Returns a rounded-tile radius at the requested side length.
    ///
    /// - Parameter side: The side length in points or pixels.
    /// - Returns: A radius clamped to the tile's valid range.
    public func tileCornerRadius(for side: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        let radius = (side * tileCornerRadiusRatio).rounded()
        return min(side / 2, max(0, radius))
    }

    /// The helper icon's rounded plate radius at source-canvas resolution.
    public var helperIconCornerRadius: CGFloat {
        tileCornerRadius(for: helperIconCanvasSize.width)
    }

    /// The transformed cursor bounds in helper-icon canvas coordinates.
    public var helperIconCursorBoundsInCanvas: CGRect {
        CGRect(
            x: helperIconCursorTranslation.x
                + helperIconCursorPathBounds.minX * helperIconCursorScale,
            y: helperIconCursorTranslation.y
                + helperIconCursorPathBounds.minY * helperIconCursorScale,
            width: helperIconCursorPathBounds.width * helperIconCursorScale,
            height: helperIconCursorPathBounds.height * helperIconCursorScale
        )
    }

    /// Reports whether the transformed cursor bounds are centered in the canvas.
    ///
    /// - Parameter tolerance: The permitted midpoint distance on either axis.
    /// - Returns: `true` when both midpoint distances are within `tolerance`.
    public func helperIconCursorIsOpticallyCentered(
        tolerance: CGFloat = 0.5
    ) -> Bool {
        let bounds = helperIconCursorBoundsInCanvas
        let canvas = CGRect(origin: .zero, size: helperIconCanvasSize)
        return abs(bounds.midX - canvas.midX) <= tolerance
            && abs(bounds.midY - canvas.midY) <= tolerance
    }
}
