import AppKit
@testable import CmuxNextDesign
import Testing

/// REOPEN-F7: a reopened window's sidebar made about 100 empty labels before its first frame
/// (`ChromeLabel(font:)`: the subtitle, age, meta, tab count and PR badge of every row), and
/// each one laid an empty line out in TextKit twice (once in the default font, once in its own).
/// That was 22 to 25 ms of the profiled window build. An empty line's size is its font's line
/// height (``LabelText/WholePointLines``): it needs no layout.
@MainActor @Suite(.serialized) struct EmptyLabelMeasureTests {
    private static let sentinel = "sentinel, laid out before the label"

    private static func layOutSentinel() {
        _ = LabelText.measure(NSAttributedString(string: sentinel), font: .systemFont(ofSize: 13),
                              shape: ChromeLabel(frame: .zero).shape, width: nil, scale: 2)
        #expect(LabelText.lastLaidOutString == sentinel)
    }

    @Test func anEmptyLabelLaysNoTextOut() {
        Self.layOutSentinel()
        let label = ChromeLabel(font: .systemFont(ofSize: 11))
        _ = label.intrinsicContentSize
        _ = label.firstBaselineOffsetFromTop
        #expect(LabelText.lastLaidOutString == Self.sentinel, "an empty label laid its line out in TextKit")
        #expect(label.frame.height > 0)
    }

    @Test func anEmptyLabelLaysOutAsTextKitWould() {
        let fonts: [NSFont] = [.systemFont(ofSize: 13), .systemFont(ofSize: 11), .systemFont(ofSize: 10.5),
                               .monospacedSystemFont(ofSize: 12, weight: .regular), .boldSystemFont(ofSize: 17),
                               .systemFont(ofSize: 9.5)]
        var shapes = [ChromeLabel(frame: .zero).shape, ChromeLabel(font: .systemFont(ofSize: 13)).shape,
                      ChromeLabel(wrappingLabelWithString: "").shape]
        var twoLines = shapes[2]
        twoLines.lines = 2
        twoLines.truncatesLastVisibleLine = true
        shapes.append(twoLines)
        let empty = NSAttributedString()
        for font in fonts {
            for shape in shapes {
                for scale: CGFloat in [1, 2, 3] {
                    let measured = LabelText.measure(empty, font: font, shape: shape, width: nil, scale: scale)
                    let laidOut = LabelText.laidOutMetrics(empty, font: font, shape: shape, width: nil, scale: scale)
                    #expect(measured == laidOut, "\(font.fontName) \(font.pointSize) pt, \(shape), scale \(scale)")
                }
            }
        }
        // No font: the system font, as TextKit lays it out.
        let shape = shapes[0]
        #expect(LabelText.measure(empty, font: nil, shape: shape, width: nil, scale: 2)
            == LabelText.laidOutMetrics(empty, font: nil, shape: shape, width: nil, scale: 2))
    }
}
