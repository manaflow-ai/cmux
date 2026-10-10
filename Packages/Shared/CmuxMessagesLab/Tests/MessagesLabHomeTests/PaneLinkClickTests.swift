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

    /// A Chief subagent's link in agent text is a link (`URL.isChiefSubagentLink`: only
    /// `cmux://chief/<home id>/session/<id>`), and a click hands it to the host's app-link
    /// handler (the app's `link.open`), never to the system; any other cmux:// text stays text.
    @Test func aSubagentLinkIsALinkAndItsClickGoesToTheApp() throws {
        HomeMarkdownPolicy.installed = false
        let (p, c) = Fixture2.projection()
        let link = "cmux://chief/0a1b2c3d/session/01a12318-9c7f-7000-beab-7686172b0ca3"
        #expect(try #require(URL(string: link)).isChiefSubagentLink)
        #expect(MarkdownLinkPolicy.sanitize(link) == link)
        #expect(MDInlineParser.parse("[a1](\(link))").spans.compactMap(\.link) == [link])
        // Its own message id: the measure cache keys by message id, not text (another test's msg_1).
        p.apply(items: [Fixture2.item(917, Fixture2.them, "Started [a1](\(link)); not [this](cmux://open) or [that](cmux://tab/tab_1)."),
                        Fixture2.item(918, Fixture2.me, "ok"),
                        Fixture2.item(919, Fixture2.them, "Read [the docs](https://cmux.com/docs).")],
                summary: Fixture2.summary(lastSeq: 919), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded(); c.demo!.layoutIfNeeded(); c.demo!.collection.layoutIfNeeded()
        var found: CGPoint?
        var links = Set<String>()
        let b = c.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                guard let url = c.linkURL(at: CGPoint(x: x, y: y)) else { continue }
                links.insert(url.absoluteString)
                if found == nil, url.absoluteString == link { found = CGPoint(x: x, y: y) }
            }
        }
        #expect(links == [link, "https://cmux.com/docs"], "only the subagent link and the https link are links: \(links)")
        var opened: [URL] = []
        c.onAppLink = { opened.append($0) }
        let point = try #require(found)
        let hit = try #require(c.demo?.hit(point))
        #expect(c.openLink(hit, at: point))
        #expect(opened.map(\.absoluteString) == [link])
        #expect(!URL(string: "cmux://chief/0a1b2c3d/session/s1?x=1")!.isChiefSubagentLink)
        #expect(!URL(string: "cmux-dev://chief/0a1b2c3d/session/s1")!.isChiefSubagentLink)
    }

    @Test func aClickOpensOnlyHttpHttpsAndMailto() {
        let (p, c) = Fixture2.projection()
        let items = [
            Fixture2.item(1, Fixture2.them, "Read [the docs](https://cmux.com/docs), not [this](javascript:alert(1)) or [that](file:///etc/passwd)."),
            Fixture2.item(2, Fixture2.me, "Mine: file:///etc/passwd and https://cmux.com/me and mailto:a@cmux.com"),
            Fixture2.item(3, Fixture2.them, "Image: ![chart](https://example.com/chart.png)"),
        ]
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 3), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded(); c.demo!.layoutIfNeeded(); c.demo!.collection.layoutIfNeeded()
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
