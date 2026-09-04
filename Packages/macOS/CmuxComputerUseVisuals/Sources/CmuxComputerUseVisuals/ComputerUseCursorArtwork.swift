public import CoreGraphics

/// Provides the canonical Computer Use cursor path and its measured artwork geometry.
///
/// The value has no mutable state. Keeping path construction and bound-based
/// placement here gives the app renderer and the checked-in helper icon
/// generator one geometry contract.
nonisolated public struct ComputerUseCursorArtwork: Sendable {
    /// Creates the stateless cursor artwork value.
    public init() {}

    /// The source canvas used by the helper icon.
    public static let defaultCanvasSize = CGSize(width: 1_024, height: 1_024)

    /// The scale from the source cursor path to helper-icon pixels.
    public static let defaultScale: CGFloat = 44.8

    /// The width of the helper icon's inner rim stroke.
    public static let defaultRimWidth: CGFloat = 14

    /// The rounded-tile corner-radius ratio shared by the helper icon and UI tiles.
    public static let tileCornerRadiusRatio: CGFloat = 7.0 / 32.0

    /// The SVG path data for the cursor silhouette.
    public static let svgPathData =
        "M0.68 1.83 L3.63 9.78 Q4.67 12.59 5.3 9.66 L5.44 9.01 Q6.08 6.08 9.01 5.44 L9.66 5.3 Q12.59 4.67 9.78 3.63 L1.83 0.68 Q0 0 0.68 1.83 Z"

    /// Builds the exact Sky kite path used by the live cursor and helper icon.
    public func path() -> CGPath {
        let kite = CGMutablePath()
        kite.move(to: CGPoint(x: 0.68, y: 1.83))
        kite.addLine(to: CGPoint(x: 3.63, y: 9.78))
        kite.addQuadCurve(
            to: CGPoint(x: 5.3, y: 9.66),
            control: CGPoint(x: 4.67, y: 12.59)
        )
        kite.addLine(to: CGPoint(x: 5.44, y: 9.01))
        kite.addQuadCurve(
            to: CGPoint(x: 9.01, y: 5.44),
            control: CGPoint(x: 6.08, y: 6.08)
        )
        kite.addLine(to: CGPoint(x: 9.66, y: 5.3))
        kite.addQuadCurve(
            to: CGPoint(x: 9.78, y: 3.63),
            control: CGPoint(x: 12.59, y: 4.67)
        )
        kite.addLine(to: CGPoint(x: 1.83, y: 0.68))
        kite.addQuadCurve(
            to: CGPoint(x: 0.68, y: 1.83),
            control: CGPoint(x: 0, y: 0)
        )
        kite.closeSubpath()
        return kite
    }

    /// Returns the path's tight geometric bounds, including curve extrema.
    public func pathBounds() -> CGRect {
        path().boundingBoxOfPath
    }

    /// Computes the translation that centers the tight path bounds in a canvas.
    ///
    /// - Parameters:
    ///   - canvasSize: The destination canvas size.
    ///   - scale: The scale applied to source path units.
    /// - Returns: A translation in destination-canvas coordinates.
    public func centeredTranslation(
        canvasSize: CGSize = Self.defaultCanvasSize,
        scale: CGFloat = Self.defaultScale
    ) -> CGPoint {
        let bounds = pathBounds()
        return CGPoint(
            x: (canvasSize.width - bounds.width * scale) / 2
                - bounds.minX * scale,
            y: (canvasSize.height - bounds.height * scale) / 2
                - bounds.minY * scale
        )
    }

    /// Returns the transformed tight path bounds in canvas coordinates.
    ///
    /// - Parameters:
    ///   - canvasSize: The destination canvas size.
    ///   - scale: The scale applied to source path units.
    /// - Returns: The visible path bounds after centering.
    public func transformedBounds(
        canvasSize: CGSize = Self.defaultCanvasSize,
        scale: CGFloat = Self.defaultScale
    ) -> CGRect {
        let bounds = pathBounds()
        let translation = centeredTranslation(canvasSize: canvasSize, scale: scale)
        return CGRect(
            x: translation.x + bounds.minX * scale,
            y: translation.y + bounds.minY * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    /// Draws the cursor path with the cmux brand gradient.
    ///
    /// - Parameters:
    ///   - context: The Core Graphics context receiving the artwork.
    ///   - scale: The scale from source path units to context points.
    ///   - outlineColor: An optional outline color for the live pointer.
    ///   - outlineWidth: The outline width; ignored when no color is supplied.
    public func draw(
        in context: CGContext,
        scale: CGFloat,
        outlineColor: CGColor? = nil,
        outlineWidth: CGFloat = 0
    ) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let kite = path()

        if let outlineColor, outlineWidth > 0 {
            context.addPath(kite)
            context.setLineWidth(outlineWidth)
            context.setLineJoin(.round)
            context.setStrokeColor(outlineColor)
            context.strokePath()
        }

        context.saveGState()
        context.addPath(kite)
        context.clip()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(
                colorSpace: colorSpace,
                components: [0x12 / 255.0, 0xC7 / 255.0, 0xF5 / 255.0, 1.0]
            )!,
            CGColor(
                colorSpace: colorSpace,
                components: [0x2D / 255.0, 0x8C / 255.0, 0xFF / 255.0, 1.0]
            )!,
            CGColor(
                colorSpace: colorSpace,
                components: [0x6C / 255.0, 0x5C / 255.0, 0xFF / 255.0, 1.0]
            )!,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0.0, 0.5, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0.68, y: 0.68),
                end: CGPoint(x: 11.0, y: 11.0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
        context.restoreGState()
    }
}
