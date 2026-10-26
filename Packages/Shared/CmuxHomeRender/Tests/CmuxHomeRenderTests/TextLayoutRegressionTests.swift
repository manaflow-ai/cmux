import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// What HomeRenderFuzzTests (p10-stability-028) found in the text path: a mention range from the wire
/// trapped on `NSMaxRange`'s overflow when the bubble was drawn, and drawing re-walked every earlier line
/// for each line's baseline (O(lines²)).
@MainActor
@Suite struct TextLayoutRegressionTests {
    @Test func aMentionRangeOfAnyIntsIsClampedToTheText() {
        #expect(TextLayout.clamped(NSRange(location: -3, length: 5), to: 5) == NSRange(location: 0, length: 2))
        #expect(TextLayout.clamped(NSRange(location: 2, length: Int.max), to: 5) == NSRange(location: 2, length: 3))
        #expect(TextLayout.clamped(NSRange(location: Int.max, length: 1), to: 5) == nil)
        #expect(TextLayout.clamped(NSRange(location: Int.min, length: Int.max), to: 5) == nil)
        #expect(TextLayout.clamped(NSRange(location: 1, length: -4), to: 5) == nil)
        #expect(TextLayout.clamped(NSRange(location: 1, length: 2), to: 5) == NSRange(location: 1, length: 2))
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

    @Test func allLineOffsetsMatchEachLinesOffset() {
        let text = "one\ntwo wraps across the column because it is long enough to wrap twice at forty points\n\nend\n"
        let tl = TextLayout.make(text, maxWidth: 40, font: Style.bodyFont)
        for hard in [Style.lineHeight, Style.hardBreakAdvance] {
            let all = tl.lineOffsets(hard: hard)
            #expect(all.count == tl.lines.count)
            for i in tl.lines.indices { #expect(all[i] == tl.lineOffset(i, hard: hard), "line \(i)") }
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
}
