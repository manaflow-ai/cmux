import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CmuxHomeRender

/// What HomeRenderFuzzTests found in the text path: a mention range from the wire
/// trapped on `NSMaxRange`'s overflow when the bubble was drawn, a zero or NaN wrap width, and drawing that
/// re-walked every earlier line for each line's baseline (O(lines²)).
@MainActor
@Suite struct TextLayoutRegressionTests {
    /// The UTF-16 units of `tl`'s text drawn in the bold face.
    static func boldUnits(_ tl: TextLayout) -> [Int] {
        let a = tl.attributed(font: Style.bodyFont, color: CGColor(gray: 0, alpha: 1))
        let bold = Fonts.withTraits(Style.bodyFont, .traitBold)
        return (0..<a.length).filter { i in
            a.attribute(TextDraw.fontKey, at: i, effectiveRange: nil).map { CFEqual($0 as CFTypeRef, bold) } ?? false
        }
    }

    /// The Mac renderer's rule for the same wire data (`TextLayout.range(_:_:in:)` in MessagesLabHome's
    /// vendored Layout.swift): a run that does not fit the text is skipped, never cut to fit.
    @Test func aMentionThatDoesNotFitTheTextIsSkipped() {
        let text = "hello @chief" // 12 UTF-16 units
        let wire = [NSRange(location: Int.max, length: 1), NSRange(location: 3, length: Int.max), NSRange(location: -2, length: 4),
                    NSRange(location: Int.min, length: Int.max), NSRange(location: 1, length: -4), NSRange(location: 10, length: 3),
                    NSRange(location: 6, length: 6)]
        let tl = TextLayout.make(text, bold: wire, maxWidth: 1_000, font: Style.bodyFont)
        #expect(Self.boldUnits(tl) == Array(6..<12))
    }

    @Test func aBubbleWithWireMentionsPastTheTextDraws() {
        let mentions = [Mention(start: Int.max, length: 1, participant: Fixtures.chief),
                        Mention(start: 3, length: Int.max, participant: Fixtures.chief),
                        Mention(start: -2, length: 4, participant: Fixtures.chief)]
        let message = Message(id: MessageID("msg_1"), conversation: Fixtures.conversation, seq: 1, clientMessageID: IdempotencyKey("key_1"),
                              author: Fixtures.chief, parts: [.text("hello @chief", mentions: mentions)], createdAt: Fixtures.start)
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items([message]), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let spec = c.scene.model.rows.map(\.spec).first { $0.partRow?.text != nil }
        #expect(spec != nil)
        if let spec {
            let size = RowArt.frame(spec, metrics: c.scene.metrics).size
            #expect(RowArt.render(spec, palette: Fixtures.palette, size: size) != nil)
        }
    }

    @Test func aZeroOrNaNWidthStillCoversTheText() {
        for width in [CGFloat(0), -1, .nan] {
            let text = "a\u{1F468}\u{200D}\u{1F469}b\r\nc"
            let tl = TextLayout.make(text, maxWidth: width, font: Style.bodyFont)
            let end = tl.lines.last.map { $0.range.location + $0.range.length }
            #expect(end == (text as NSString).length, "width \(width)")
        }
    }

    /// A sent bubble's lines after a hard newline are `hard` apart, wrapped lines a line height.
    @Test func theTextHeightAddsEachLinesAdvance() {
        let hard = Style.hardBreakAdvance
        let broken = TextLayout.make("one\n\ntwo\n", maxWidth: 1_000, font: Style.bodyFont)
        #expect(broken.lines.count == 4)
        #expect(broken.textHeight(hard: hard) == 3 * hard + Style.lineHeight)
        let wrapped = TextLayout.make("a line long enough to wrap at forty points more than twice", maxWidth: 40, font: Style.bodyFont)
        #expect(wrapped.lines.count > 2)
        #expect(wrapped.textHeight(hard: hard) == CGFloat(wrapped.lines.count) * Style.lineHeight)
    }

    /// Drawing a bubble costs O(lines): 16 times the lines take about 16 times as long, not 256 times (the
    /// baseline of each line was summed again from the first line). The bound leaves 3x for noise; each
    /// size keeps its fastest of three draws.
    @Test func drawingABubbleCostsLinearlyInItsLines() {
        func drawTime(lines: Int) -> Duration {
            let tl = TextLayout.make(String(repeating: "a\n", count: lines), maxWidth: 1_000, font: Style.bodyFont)
            let body = CGRect(x: 0, y: 0, width: 200, height: 600)
            let clock = ContinuousClock()
            return (0..<3).map { _ in
                clock.measure {
                    _ = Canvas.image(size: CGSize(width: 240, height: 600), scale: 1) { ctx in
                        PartDrawing.drawText(ctx, tl, in: body, outgoing: true, palette: Fixtures.palette)
                    }
                }
            }.min() ?? .zero
        }
        let small = drawTime(lines: 500)
        let large = drawTime(lines: 8_000)
        #expect(large < small * 48, "500 lines: \(small), 8000 lines: \(large)")
    }
}
