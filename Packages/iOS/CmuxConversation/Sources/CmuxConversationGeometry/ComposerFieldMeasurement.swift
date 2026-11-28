import CoreGraphics
import Foundation

/// When the composer field measures its draft, and the height that
/// measure gives. The field grows by whole lines; a measure taken at one
/// text width is only good for that width.
public struct ComposerFieldMeasurement: Equatable, Sendable {
    /// The text width of the last measure (nil before the first).
    public private(set) var textWidth: CGFloat?

    public init() {}

    /// Records a measure taken with the text `textWidth` wide.
    public mutating func didMeasure(textWidth: CGFloat) {
        self.textWidth = textWidth
    }

    /// Whether a layout pass that gives the text `textWidth` needs the draft
    /// measured again: before the first measure, or at a width that differs
    /// by more than `tolerance` (pixel rounding never re-measures).
    public func needsRemeasure(textWidth: CGFloat) -> Bool {
        guard let measured = self.textWidth else { return true }
        return abs(measured - textWidth) > Self.tolerance
    }

    public static let tolerance: CGFloat = 0.5

    /// Whole lines in a text view `textHeight` tall (its fitting height,
    /// including `verticalPadding` above and below the text). The first line
    /// is `lineHeight` tall; later lines add the font's `leading` too, as
    /// TextKit lays them out (the tight-leading body font: 20.29 pt lines,
    /// -0.29 pt leading, so the field steps 20 pt a line as Messages' does).
    public static func lineCount(textHeight: CGFloat, verticalPadding: CGFloat, lineHeight: CGFloat, leading: CGFloat = 0) -> CGFloat {
        let pitch = lineHeight + leading
        guard pitch > 0 else { return 1 }
        return max(1, ((textHeight - 2 * verticalPadding - lineHeight) / pitch).rounded() + 1)
    }

    /// The field's height for `lines` lines of text.
    public static func fieldHeight(lines: CGFloat, oneLineHeight: CGFloat, lineHeight: CGFloat, leading: CGFloat = 0) -> CGFloat {
        oneLineHeight + (max(1, lines) - 1) * (lineHeight + leading)
    }
}
