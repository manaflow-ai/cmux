import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// The composer's draft is measured at its text width; a later layout at a
/// different width must measure it again (a reply on an iPhone 17 Pro Max
/// showed three lines in a 237 pt field, nine lines' worth).
@Suite struct ComposerFieldMeasurementTests {
    static let lineHeight: CGFloat = 20.29
    static let padding: CGFloat = 10
    static let oneLine = lineHeight + 2 * padding
    /// "chbcchhfjc", "c", "ckckckckc" at about 9 pt a character.
    static let paragraphs: [CGFloat] = [10, 1, 9].map { $0 * 9 }

    /// A text view's fitting height for the draft wrapped at `width`.
    static func textHeight(width: CGFloat) -> CGFloat {
        let lines = paragraphs.reduce(CGFloat(0)) { $0 + max(1, ($1 / width).rounded(.up)) }
        return lines * lineHeight + 2 * padding
    }

    /// The composer: measure on a text change, then lay out.
    struct Field {
        var measurement = ComposerFieldMeasurement()
        var height = ComposerFieldMeasurementTests.oneLine

        mutating func measure(textWidth: CGFloat) {
            let lines = ComposerFieldMeasurement.lineCount(
                textHeight: ComposerFieldMeasurementTests.textHeight(width: textWidth),
                verticalPadding: ComposerFieldMeasurementTests.padding, lineHeight: ComposerFieldMeasurementTests.lineHeight)
            height = ComposerFieldMeasurement.fieldHeight(lines: lines, oneLineHeight: ComposerFieldMeasurementTests.oneLine, lineHeight: ComposerFieldMeasurementTests.lineHeight)
            measurement.didMeasure(textWidth: textWidth)
        }

        mutating func layout(textWidth: CGFloat) {
            if measurement.needsRemeasure(textWidth: textWidth) { measure(textWidth: textWidth) }
        }
    }

    @Test func draftMeasuredNarrowShrinksToItsLinesWhenTheFieldWidens() {
        var field = Field()
        field.measure(textWidth: 30)
        #expect(field.height > ComposerFieldMeasurement.fieldHeight(lines: 6, oneLineHeight: Self.oneLine, lineHeight: Self.lineHeight))
        field.layout(textWidth: 290)
        #expect(field.height == ComposerFieldMeasurement.fieldHeight(lines: 3, oneLineHeight: Self.oneLine, lineHeight: Self.lineHeight))
    }

    @Test func aLayoutAtTheMeasuredWidthKeepsTheMeasure() {
        var measurement = ComposerFieldMeasurement()
        #expect(measurement.needsRemeasure(textWidth: 290))
        measurement.didMeasure(textWidth: 290)
        #expect(!measurement.needsRemeasure(textWidth: 290))
        #expect(!measurement.needsRemeasure(textWidth: 290.2))
        #expect(measurement.needsRemeasure(textWidth: 274))
    }

    @Test func linesRoundToWholeLines() {
        #expect(ComposerFieldMeasurement.lineCount(textHeight: 3 * Self.lineHeight + 2 * Self.padding + 2, verticalPadding: Self.padding, lineHeight: Self.lineHeight) == 3)
        #expect(ComposerFieldMeasurement.lineCount(textHeight: 0, verticalPadding: Self.padding, lineHeight: Self.lineHeight) == 1)
    }

    /// Messages' field (iOS 26 and 27, iPhone 17 Pro, Large): 40.33 pt for
    /// one line, then 20 pt a line, 120.33 for five. The tight-leading body
    /// font is 20.29 pt with -0.29 pt leading; TextKit adds the leading
    /// between lines (a UITextView with 10 pt insets fits 120.33 for five).
    @Test func linesAfterTheFirstStepByTheFontsLeadingToo() {
        let fontLine: CGFloat = 20.2871, leading: CGFloat = -0.2871
        let oneLine: CGFloat = 40.3333
        #expect(ComposerFieldMeasurement.lineCount(textHeight: 120.3333, verticalPadding: 10, lineHeight: fontLine, leading: leading) == 5)
        #expect(abs(ComposerFieldMeasurement.fieldHeight(lines: 5, oneLineHeight: oneLine, lineHeight: fontLine, leading: leading) - 120.3333) < 0.01)
        #expect(ComposerFieldMeasurement.lineCount(textHeight: 420.3333, verticalPadding: 10, lineHeight: fontLine, leading: leading) == 20)
        #expect(ComposerFieldMeasurement.fieldHeight(lines: 1, oneLineHeight: oneLine, lineHeight: fontLine, leading: leading) == oneLine)
    }
}
