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
    /// measured again.
    public func needsRemeasure(textWidth: CGFloat) -> Bool {
        false
    }

    /// Whole lines in a text view `textHeight` tall (its fitting height,
    /// including `verticalPadding` above and below the text).
    public static func lineCount(textHeight: CGFloat, verticalPadding: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard lineHeight > 0 else { return 1 }
        return max(1, ((textHeight - 2 * verticalPadding) / lineHeight).rounded())
    }

    /// The field's height for `lines` lines of text.
    public static func fieldHeight(lines: CGFloat, oneLineHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        oneLineHeight + (max(1, lines) - 1) * lineHeight
    }
}
