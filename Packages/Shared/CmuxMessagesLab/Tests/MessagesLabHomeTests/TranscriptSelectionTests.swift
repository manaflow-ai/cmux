import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// Drag selection in a markdown bubble with a table (the Chief's replies). A markdown row's
/// `text` is a one-line proxy of its display string; when the selection read it, every point
/// landed on the first line and the highlight was one line as wide as the whole message. The
/// row is built as the layout builds it (proxy and markdown layout both set), so the tests go
/// through the row's geometry choice, not only the markdown layout.
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

    static func row() throws -> (PartRow, MarkdownLayout, RowTextGeometry) {
        let md = MarkdownLayoutEngine.layout(Markdown.parse(source), source: source, maxWidth: Fixture.windowWidth)
        let row = PartRow(ref: PartRef(messageId: "msg_md", partIndex: 0), part: .text(source, runs: []), outgoing: false, tail: true,
                          reactions: [], failed: false, size: md.size, text: md.proxy, connectorRoot: nil, markdown: md, markdownFormat: true)
        return (row, md, try #require(row.geometry(width: Fixture.windowWidth)))
    }

    @Test func aPointInATableRowBelowTheFirstLineMapsToTheTextUnderIt() throws {
        let (_, md, g) = try Self.row()
        let body = CGRect(x: 10, y: 50, width: md.size.width, height: md.size.height)
        let target = (md.plain as NSString).range(of: "workspace-2")
        try #require(target.location != NSNotFound)
        let frag = try #require(md.frags.first { NSLocationInRange(target.location, $0.range) })
        let x = CTLineGetOffsetForStringIndex(frag.line, target.location - frag.range.location, nil) + 2
        let p = CGPoint(x: body.minX + frag.origin.x + x, y: body.minY + frag.origin.y + frag.height / 2)
        let pos = TranscriptSelection.position(at: p, body: body, key: "row", geometry: g)
        #expect(NSLocationInRange(pos.offset, NSRange(location: target.location, length: target.length + 1)),
                "offset \(pos.offset) is not in \"workspace-2\" at \(target)")
    }

    @Test func theHighlightCoversEveryLineAndTableCell() throws {
        let (_, md, g) = try Self.row()
        let body = CGRect(x: 0, y: 0, width: md.size.width, height: md.size.height)
        let rects = TranscriptSelection.highlightRects(NSRange(location: 0, length: md.length), body: body, geometry: g, visible: 0...body.maxY)
        // The first paragraph, the table's rows and the closing paragraph each draw their own rect.
        #expect(Set(rects.map(\.minY)).count >= 5)
        for f in md.frags where f.role == .body && f.range.length > 0 {
            let glyphs = CGRect(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height).insetBy(dx: 1, dy: 1)
            #expect(rects.contains { $0.intersects(glyphs) }, "text \(f.range) is not highlighted")
        }
    }
}
