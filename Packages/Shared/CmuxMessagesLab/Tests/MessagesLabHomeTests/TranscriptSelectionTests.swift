import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// Drag selection in a markdown bubble (the Chief's replies): a markdown row's `text` is a
/// one-line proxy of its display string, so the selection must map points and draw the
/// highlight from the markdown layout, or every point lands on the first line and the
/// highlight is one line as wide as the whole message.
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

    static func row() throws -> (PartRow, MarkdownLayout) {
        let md = try #require(Markdown.layout(source, message: "msg_md", format: .markdown, width: Fixture.windowWidth))
        let row = PartRow(ref: PartRef(messageId: "msg_md", partIndex: 0), part: .text(source, runs: []), outgoing: false, tail: true,
                          reactions: [], failed: false, size: md.size, text: md.proxy, connectorRoot: nil, markdown: md, markdownFormat: true)
        return (row, md)
    }

    @Test func aPointBelowTheFirstLineMapsToTheTextUnderIt() throws {
        let (row, md) = try Self.row()
        let ns = md.plain as NSString
        let target = ns.range(of: "workspace-2")
        let frag = try #require(md.frags.first { NSLocationInRange(target.location, $0.range) })
        let x = CTLineGetOffsetForStringIndex(frag.line, target.location - frag.range.location, nil) + 2
        let p = CGPoint(x: frag.origin.x + x, y: frag.origin.y + frag.height / 2)
        let offset = try #require(TranscriptSelection.offset(in: row, at: p))
        #expect(NSLocationInRange(offset, NSRange(location: target.location, length: target.length + 1)),
                "offset \(offset) is not in \"workspace-2\" at \(target)")
    }

    @Test func theHighlightFollowsTheMarkdownLinesInsideTheBubble() throws {
        let (row, md) = try Self.row()
        let rects = TranscriptSelection.highlightRects(in: row, range: NSRange(location: 0, length: md.length))
        // The heading line, the table's rows and the closing paragraph each draw their own rect.
        #expect(Set(rects.map(\.minY)).count >= 5)
        for r in rects { #expect(r.maxX <= md.size.width + 1, "rect \(r) runs past the bubble (\(md.size.width) pt)") }
    }
}
