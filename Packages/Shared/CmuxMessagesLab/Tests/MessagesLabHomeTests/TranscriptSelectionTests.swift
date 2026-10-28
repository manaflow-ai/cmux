import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// Drag selection in a markdown bubble with a table (the Chief's replies): the selection maps
/// points and draws the highlight from the row's markdown geometry, so a point in a table row
/// below the first line lands on that row's text and every line and table row is highlighted.
@MainActor @Suite struct TranscriptSelectionMarkdownTests {
    static let source = """
    You have 3 workspaces in this cmux session:

    | # | Name | ID |
    | --- | --- | --- |
    | 0 | Home | ws_f639b5e24bc85f14 |
    | 1 | workspace-1 | ws_2292be58ebd3cd7a |
    | 2 | workspace-2 | ws_a13335440412f472 |

    Home has a single browser tab that shows about:blank.
    """

    static func layout() -> MarkdownLayout {
        MarkdownLayoutEngine.layout(Markdown.parse(source), source: source, maxWidth: Fixture.windowWidth)
    }

    @Test func aPointInATableRowBelowTheFirstLineMapsToTheTextUnderIt() throws {
        let md = Self.layout()
        let body = CGRect(x: 10, y: 50, width: md.size.width, height: md.size.height)
        let target = (md.plain as NSString).range(of: "workspace-2")
        try #require(target.location != NSNotFound)
        let frag = try #require(md.frags.first { NSLocationInRange(target.location, $0.range) })
        let x = CTLineGetOffsetForStringIndex(frag.line, target.location - frag.range.location, nil) + 2
        let p = CGPoint(x: body.minX + frag.origin.x + x, y: body.minY + frag.origin.y + frag.height / 2)
        let pos = TranscriptSelection.position(at: p, body: body, key: "row", geometry: md)
        #expect(NSLocationInRange(pos.offset, NSRange(location: target.location, length: target.length + 1)),
                "offset \(pos.offset) is not in \"workspace-2\" at \(target)")
    }

    @Test func theHighlightFollowsTheMarkdownLinesAndTableRowsInsideTheBubble() throws {
        let md = Self.layout()
        let body = CGRect(x: 0, y: 0, width: md.size.width, height: md.size.height)
        let rects = TranscriptSelection.highlightRects(NSRange(location: 0, length: md.length), body: body, geometry: md, visible: 0...body.maxY)
        // The heading line, the table's rows and the closing paragraph each draw their own rect.
        #expect(Set(rects.map(\.minY)).count >= 5)
        for r in rects { #expect(body.contains(r), "rect \(r) leaves the bubble \(body)") }
    }
}
