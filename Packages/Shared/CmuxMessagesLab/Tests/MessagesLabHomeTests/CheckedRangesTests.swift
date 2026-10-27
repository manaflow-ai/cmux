import AppKit
import CoreText
import Foundation
import Testing
@testable import MessagesLabHome

/// p10-stability-169: the NSString and NSAttributedString range checks (`Cmux/CheckedRanges.swift`) and the
/// transcript paths that take them. A range or index past the end raises NSRangeException, which Swift's `try`
/// does not catch, so a line or run measured for another text (a row drawn before its new layout lands) ended
/// the process. Now that line, run or attribute is skipped.
@MainActor @Suite struct CheckedRangesTests {
    // MARK: The helpers: nil outside the text, never a clamped value

    @Test func stringRangeIsCheckedAgainstTheUTF16Length() {
        let s = "héllo" as NSString
        #expect(s.checkedRange(NSRange(location: 0, length: 5)) == NSRange(location: 0, length: 5))
        #expect(s.checkedRange(NSRange(location: 5, length: 0)) == NSRange(location: 5, length: 0)) // empty at the end
        #expect(s.checkedRange(NSRange(location: 4, length: 2)) == nil)
        #expect(s.checkedRange(NSRange(location: 6, length: 0)) == nil)
        #expect(s.checkedRange(NSRange(location: -1, length: 1)) == nil)
        #expect(s.checkedRange(NSRange(location: 1, length: -1)) == nil)
        #expect(s.checkedRange(NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(s.checkedRange(NSRange(location: 1, length: Int.max)) == nil) // the check itself cannot overflow
    }

    @Test func stringIndexSubstringAndCharacter() {
        let s = "a👍b" as NSString // the emoji is two UTF-16 units
        #expect(s.length == 4)
        #expect(s.checkedIndex(0) == 0)
        #expect(s.checkedIndex(3) == 3)
        #expect(s.checkedIndex(4) == nil)
        #expect(s.checkedIndex(-1) == nil)
        #expect(s.checkedSubstring(NSRange(location: 1, length: 2)) == "👍")
        #expect(s.checkedSubstring(NSRange(location: 3, length: 2)) == nil)
        #expect(s.checkedSubstring(NSRange(location: 4, length: 0)) == "")
        #expect(s.checkedCharacter(at: 0) == 0x61)
        #expect(s.checkedCharacter(at: 3) == 0x62)
        #expect(s.checkedCharacter(at: 4) == nil)
        #expect(s.checkedCharacter(at: -1) == nil)
    }

    @Test func attributedRangeIndexSubstringAndAttributes() {
        let a = NSAttributedString(string: "ab", attributes: [.kern: 2])
        #expect(a.checkedRange(NSRange(location: 0, length: 2)) == NSRange(location: 0, length: 2))
        #expect(a.checkedRange(NSRange(location: 1, length: 2)) == nil)
        #expect(a.checkedIndex(1) == 1)
        #expect(a.checkedIndex(2) == nil)
        #expect(a.checkedAttributedSubstring(NSRange(location: 1, length: 1))?.string == "b")
        #expect(a.checkedAttributedSubstring(NSRange(location: 2, length: 1)) == nil)
        #expect(a.checkedAttribute(.kern, at: 1) as? Int == 2)
        #expect(a.checkedAttribute(.kern, at: 2) == nil)
        #expect(a.checkedAttribute(.link, at: 0) == nil)
        #expect(a.checkedAttributes(at: 0)?[.kern] as? Int == 2)
        #expect(a.checkedAttributes(at: 2) == nil)
    }

    // MARK: Lines and runs measured for another text

    /// A short bubble drawn with the lines of a longer text: `attributedSubstring(from:)` of the second line raised
    /// NSRangeException before the check (the run ended in a crash, so a finished test is the proof).
    @Test func drawTextSkipsALineOutsideItsText() throws {
        let tl = TextLayout(text: "hi", runs: [], lines: [
            TextLayout.Line(range: NSRange(location: 0, length: 2), width: 12, fit: 12),
            TextLayout.Line(range: NSRange(location: 2, length: 40), width: 120, fit: 120),
            TextLayout.Line(range: NSRange(location: 90, length: 3), width: 20, fit: 20),
        ], width: 120)
        let ctx = try #require(CGContext.ownedBitmap(width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        PartRenderer.drawText(ctx, tl, in: CGRect(x: 0, y: 0, width: 160, height: 80), outgoing: false)
        PartRenderer.drawText(ctx, tl, in: CGRect(x: 0, y: 0, width: 160, height: 80), outgoing: true)
        #expect(tl.link(at: CGPoint(x: 4, y: Fixture.lineHeight * 1.5)) == nil)
    }

    /// Stale lines through the selection geometry: every answer stays inside the text.
    @Test func selectionGeometryWithStaleLinesStaysInsideTheText() {
        let tl = TextLayout(text: "hello", runs: [], lines: [
            TextLayout.Line(range: NSRange(location: 0, length: 3), width: 20, fit: 20),
            TextLayout.Line(range: NSRange(location: 3, length: 30), width: 200, fit: 200),
        ], width: 200)
        let g = ShortTextGeometry(tl: tl)
        #expect(g.substring(NSRange(location: 3, length: 50)) == "lo")
        #expect(g.substring(NSRange(location: 9, length: 2)) == "")
        _ = g.selectionRects(NSRange(location: 0, length: 33), visible: 0...200)
        let lh = Fixture.lineHeight
        for y in stride(from: CGFloat(0), through: lh * 2, by: lh / 2) {
            let i = g.characterIndex(at: CGPoint(x: Fixture.bubblePadX + 50, y: Fixture.bubblePadY + y))
            #expect(i >= 0 && i <= 5)
        }
    }

    /// The runs' attributes, now set once per run on its checked range: the later attribute wins as before, and a
    /// run past the end is skipped.
    @Test func attributedSetsEachRunOnceAndSkipsARunPastTheEnd() {
        let runs = [
            TextRun(start: 0, length: 2, style: ["underline", "quote"], link: nil, mention: nil, detected: nil),
            TextRun(start: 3, length: 99, style: ["strikethrough"], link: nil, mention: nil, detected: nil),
            TextRun(start: -1, length: 2, style: ["underline"], link: nil, mention: nil, detected: nil),
        ]
        let a = TextLayout(text: "hi there", runs: runs, lines: [], width: 0).attributed(color: .white, linkColor: .white)
        #expect(a.checkedAttribute(.underlineStyle, at: 0) as? Int == NSUnderlineStyle.single.rawValue)
        #expect((a.checkedAttribute(.foregroundColor, at: 1) as? NSColor)?.alphaComponent ?? 1 < 0.7)
        #expect(a.checkedAttribute(.underlineStyle, at: 2) == nil)
        #expect(a.checkedAttribute(.strikethroughStyle, at: 3) == nil)
        #expect(a.checkedAttribute(.strikethroughStyle, at: 7) == nil)
    }

    // MARK: The rewritten readers give the answers they gave

    @Test func metaTagsReadBothQuoteStyles() {
        let html = #"<meta property="og:title" content="A &amp; B"><meta name='twitter:card' content='summary'>"#
        let tags = LinkPreviews.metaTags(html)
        #expect(tags["og:title"] == "A & B")
        #expect(tags["twitter:card"] == "summary")
        #expect(LinkPreviews.titleTag("<title> Hello </title>") == "Hello")
        #expect(LinkPreviews.titleTag("<title></title>") == nil)
    }

    @Test func caretAfterRebuildFollowsAnInsertedMark() {
        let old = "ab" as NSString, new = "a\u{FFFC}b" as NSString
        let none = NSRange(location: 0, length: 0)
        #expect(ComposeView.caretAfterRebuild(old: old, new: new, selection: none) == NSRange(location: 2, length: 0))
        let end = "ab\u{FFFC}" as NSString
        #expect(ComposeView.caretAfterRebuild(old: old, new: end, selection: none) == NSRange(location: 3, length: 0))
        // Not one mark more: the selection, clamped to the new text as before.
        #expect(ComposeView.caretAfterRebuild(old: old, new: "a" as NSString, selection: NSRange(location: 1, length: 4))
            == NSRange(location: 1, length: 0))
    }

    @Test func blockLinesKeepsTextWithoutAttachments() {
        let plain = NSAttributedString(string: "one\ntwo")
        #expect(ComposeInlineText.blockLines(plain).string == "one\ntwo")
        #expect(ComposeInlineText.orphanRanges(in: NSAttributedString(string: "a\u{FFFC}b"), keeping: []) == [NSRange(location: 1, length: 1)])
    }
}
