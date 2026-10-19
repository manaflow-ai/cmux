import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// Drag-select highlight in the Home transcript (scrawl 2026-10-18: "highlighting ... is broken
/// for the iMessage UI"). A markdown row's `text` is a one-line proxy of its display string; the
/// selection hit-tested and highlighted through it, so the highlight ran past the bubble and off
/// the glyphs. The selection now uses the row's drawn geometry.
@MainActor @Suite struct TranscriptSelectionGeometryTests {
    static let source = """
    I checked, and acpmux is actually running fine for me, so my agents are working. The banner comes from a different cmux app.

    - What's running: my acpmux belongs to cmux NIGHTLY and its log shows no errors since Oct 17.
    - Where the banner comes from: all the cmux-next apps share one Chief folder.

    Still running: a18, a21 and a27.
    """

    static func layout() -> MarkdownLayout {
        MarkdownLayoutEngine.layout(Markdown.parse(source), source: source, maxWidth: 300)
    }

    @Test func fullSelectionHighlightsEveryDrawnLineInsideTheBubble() throws {
        let md = Self.layout()
        let body = CGRect(x: 40, y: 200, width: md.size.width, height: md.size.height)
        let all = NSRange(location: 0, length: md.length)
        let rects = TranscriptSelection.highlightRects(all, body: body, geometry: md, visible: body.minY...body.maxY)
        // One rect per drawn text line at least (the paragraphs wrap at 300 pt).
        let textFrags = md.frags.filter { $0.role == .body && $0.range.length > 0 }
        #expect(rects.count >= textFrags.count)
        #expect(Set(rects.map { $0.minY }).count >= 5)
        for r in rects { #expect(body.contains(r), "highlight \(r) leaves the bubble \(body)") }
        // Each drawn line is covered where its glyphs are.
        for f in textFrags {
            let glyphs = CGRect(x: body.minX + f.origin.x, y: body.minY + f.origin.y, width: f.width, height: f.height).insetBy(dx: 1, dy: 1)
            #expect(rects.contains { $0.intersects(glyphs) }, "line \(f.range) is not highlighted")
        }
    }

    @Test func partialSelectionStaysOnItsGlyphs() throws {
        let md = Self.layout()
        let body = CGRect(x: 0, y: 0, width: md.size.width, height: md.size.height)
        let word = (md.plain as NSString).range(of: "acpmux")
        try #require(word.location != NSNotFound)
        let rects = TranscriptSelection.highlightRects(word, body: body, geometry: md, visible: 0...body.maxY)
        #expect(rects.count == 1)
        let f = try #require(md.frags.first { NSLocationInRange(word.location, $0.range) })
        let r = try #require(rects.first)
        // Same line as the word, and only the word's width (not the line or the column).
        #expect(abs(r.minY - f.origin.y) < 0.5)
        #expect(r.minX >= f.origin.x)
        #expect(r.width < 80)
    }

    @Test func aPointOnALineMapsToThatLinesText() throws {
        let md = Self.layout()
        let body = CGRect(x: 10, y: 50, width: md.size.width, height: md.size.height)
        let target = (md.plain as NSString).range(of: "Still running")
        let f = try #require(md.frags.first { NSLocationInRange(target.location, $0.range) })
        let p = CGPoint(x: body.minX + f.origin.x + 1, y: body.minY + f.origin.y + f.height / 2)
        let pos = TranscriptSelection.position(at: p, body: body, key: "row", geometry: md)
        #expect(abs(pos.offset - target.location) <= 1)
        // Above and below the body clamp to the ends.
        #expect(TranscriptSelection.position(at: CGPoint(x: 20, y: 0), body: body, key: "row", geometry: md).offset == 0)
        #expect(TranscriptSelection.position(at: CGPoint(x: 20, y: body.maxY + 30), body: body, key: "row", geometry: md).offset == md.length)
    }
}
