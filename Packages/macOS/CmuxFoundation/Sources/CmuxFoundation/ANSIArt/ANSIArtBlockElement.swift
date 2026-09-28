public import CoreGraphics

/// The geometry of a Unicode block element (U+2580...U+259F), so art made of
/// half blocks and quadrants (`chafa`, image-to-text tools) can be drawn as
/// exact cell rectangles, the way terminals draw them, instead of font glyphs
/// that leave seams between rows.
///
/// ```swift
/// if let block = ANSIArtBlockElement("▀") {
///     for unit in block.rects { /* scale `unit` into the cell */ }
/// }
/// ```
public struct ANSIArtBlockElement: Hashable, Sendable {
    /// The filled parts of the cell, in unit coordinates: origin at the
    /// cell's top-left, y growing downward, 1 x 1 being the whole cell.
    public let rects: [CGRect]
    /// The fill opacity: 1 for solid blocks, 0.25/0.5/0.75 for the shades
    /// ░ ▒ ▓.
    public let opacity: Double

    private static let upperLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
    private static let upperRight = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
    private static let lowerLeft = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
    private static let lowerRight = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)

    /// The geometry for `scalar`, or `nil` when it is not a block element.
    ///
    /// - Parameter scalar: A character from the art.
    public init?(_ scalar: Unicode.Scalar) {
        let value = Int(scalar.value)
        var opacity = 1.0
        let rects: [CGRect]
        switch value {
        case 0x2580:
            rects = [CGRect(x: 0, y: 0, width: 1, height: 0.5)]
        case 0x2581...0x2588:
            // Lower one eighth through full block.
            let height = CGFloat(value - 0x2580) / 8
            rects = [CGRect(x: 0, y: 1 - height, width: 1, height: height)]
        case 0x2589...0x258F:
            // Left seven eighths down to left one eighth.
            rects = [CGRect(x: 0, y: 0, width: CGFloat(0x2590 - value) / 8, height: 1)]
        case 0x2590:
            rects = [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case 0x2591...0x2593:
            opacity = Double(value - 0x2590) / 4
            rects = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case 0x2594:
            rects = [CGRect(x: 0, y: 0, width: 1, height: 0.125)]
        case 0x2595:
            rects = [CGRect(x: 0.875, y: 0, width: 0.125, height: 1)]
        case 0x2596: rects = [Self.lowerLeft]
        case 0x2597: rects = [Self.lowerRight]
        case 0x2598: rects = [Self.upperLeft]
        case 0x2599: rects = [Self.upperLeft, Self.lowerLeft, Self.lowerRight]
        case 0x259A: rects = [Self.upperLeft, Self.lowerRight]
        case 0x259B: rects = [Self.upperLeft, Self.upperRight, Self.lowerLeft]
        case 0x259C: rects = [Self.upperLeft, Self.upperRight, Self.lowerRight]
        case 0x259D: rects = [Self.upperRight]
        case 0x259E: rects = [Self.upperRight, Self.lowerLeft]
        case 0x259F: rects = [Self.upperRight, Self.lowerLeft, Self.lowerRight]
        default:
            return nil
        }
        self.rects = rects
        self.opacity = opacity
    }
}
