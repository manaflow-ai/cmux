import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A host may allow extra schemes; a click re-checks every link (MarkdownLinkPolicy).
@MainActor @Suite(.serialized) struct PaneLinkClickTests {
    @Test func aHostCanAllowAnExtraScheme() {
        #expect(MDInlineParser.parse("[x](cmux://open)").spans.compactMap(\.link).isEmpty)
        MarkdownLinkPolicy.extraSchemes = ["cmux"]
        defer { MarkdownLinkPolicy.extraSchemes = [] }
        #expect(MDInlineParser.parse("[x](cmux://open)").spans.compactMap(\.link) == ["cmux://open"])
        #expect(MDInlineParser.parse("[x](javascript:alert(1))").spans.compactMap(\.link).isEmpty)
    }

    @Test func aClickOpensOnlyHttpHttpsAndMailto() {
        let (p, c) = Fixture2.projection()
        let items = [
            Fixture2.item(1, Fixture2.them, "Read [the docs](https://cmux.com/docs), not [this](javascript:alert(1)) or [that](file:///etc/passwd)."),
            Fixture2.item(2, Fixture2.me, "Mine: file:///etc/passwd and https://cmux.com/me and mailto:a@cmux.com"),
            Fixture2.item(3, Fixture2.them, "Image: ![chart](https://example.com/chart.png)"),
        ]
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 3), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded(); c.demo.layoutIfNeeded(); c.demo.collection.layoutIfNeeded()
        var opened = Set<String>()
        let b = c.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                if let url = c.linkURL(at: CGPoint(x: x, y: y)) { opened.insert(url.absoluteString) }
            }
        }
        #expect(opened.contains("https://cmux.com/docs"), "an allowed link opens: \(opened)")
        #expect(opened.allSatisfy { ["http", "https", "mailto"].contains(URL(string: $0)?.scheme ?? "") }, "opened: \(opened)")
    }
}
