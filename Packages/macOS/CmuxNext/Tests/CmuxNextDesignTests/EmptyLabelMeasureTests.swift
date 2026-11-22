import AppKit
@testable import CmuxNextDesign
import Testing

/// REOPEN-F7: a reopened window's sidebar made about 100 empty labels before its first frame
/// (`ChromeLabel(font:)`: the subtitle, age, meta, tab count and PR badge of every row), and
/// each one laid an empty line out in TextKit twice (once in the default font, once in its own).
/// That was 22 to 25 ms of the profiled window build. An empty line's size is its font's line
/// height (``LabelText/WholePointLines``): it needs no layout.
@MainActor @Suite(.serialized) struct EmptyLabelMeasureTests {
    private static let fonts: [NSFont?] = [.systemFont(ofSize: 13), .systemFont(ofSize: 11), .systemFont(ofSize: 10.5),
                                           .monospacedSystemFont(ofSize: 12, weight: .regular), .boldSystemFont(ofSize: 17),
                                           .systemFont(ofSize: 9.5), NSFont(name: "Times New Roman", size: 14), nil]

    private static var shapes: [LabelText.Shape] {
        var shapes = [ChromeLabel(frame: .zero).shape, ChromeLabel(font: .systemFont(ofSize: 13)).shape,
                      ChromeLabel(wrappingLabelWithString: "").shape]
        var twoLines = shapes[2]
        twoLines.lines = 2
        twoLines.truncatesLastVisibleLine = true
        shapes.append(twoLines)
        return shapes
    }

    @Test func anEmptyLabelLaysNoTextOut() {
        var layouts = 0
        let counting: LabelText.Layout = { text, font, shape, width, scale in
            layouts += 1
            return LabelText.laidOutMetrics(text, font: font, shape: shape, width: width, scale: scale)
        }
        for font in Self.fonts {
            for shape in Self.shapes {
                _ = LabelText.measure(NSAttributedString(), font: font, shape: shape, width: nil, scale: 2, layOut: counting)
            }
        }
        #expect(layouts == 0, "an empty label at an unbounded width laid its line out in TextKit")
        // Text, and an empty text at a set width, still lay out.
        _ = LabelText.measure(NSAttributedString(string: "Title"), font: nil, shape: Self.shapes[0], width: nil, scale: 2, layOut: counting)
        _ = LabelText.measure(NSAttributedString(), font: nil, shape: Self.shapes[2], width: 120, scale: 2, layOut: counting)
        #expect(layouts == 2)
    }

    @Test func anEmptyLabelLaysOutAsTextKitWould() {
        let empty = NSAttributedString()
        for font in Self.fonts {
            for shape in Self.shapes {
                for scale: CGFloat in [1, 2, 3] {
                    let measured = LabelText.measure(empty, font: font, shape: shape, width: nil, scale: scale)
                    let laidOut = LabelText.laidOutMetrics(empty, font: font, shape: shape, width: nil, scale: scale)
                    #expect(measured == laidOut, "\(font?.fontName ?? "no font") \(font?.pointSize ?? 0) pt, \(shape), scale \(scale)")
                }
            }
        }
    }
}
