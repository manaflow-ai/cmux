import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Messages' link rule on the Home path (MessagesLab cd2bc08). Lawrence's bug:
/// "https://github.com/manaflow-ai/cmux" on one line and "is this the right
/// repo?" on the next drew a truncated URL bubble, the second line with no
/// bubble, and an empty "github.com" card. HomeStore stores one text part;
/// the projection must show it as Messages does (the URL line is the card,
/// the other line one text bubble), and a text replaced under the same id
/// must be measured again (the size cache keyed a part by id only).
@MainActor @Suite(.serialized) struct LinkRuleTests {
    let me = Fixture2.me, them = Fixture2.them
    static let urlAndText = "https://github.com/manaflow-ai/cmux\nis this the right repo?"

    private func parts(_ author: ParticipantID, _ text: String) -> [Part] {
        HomeMapping.message(Fixture2.item(1, author, text), aliases: [:], me: me, summary: Fixture2.summary(lastSeq: 1)).parts
    }

    @Test func aURLLineAndATextLineAreOneCardAndOneTextBubble() throws {
        let shown = parts(me, Self.urlAndText)
        try #require(shown.count == 2, "card + text bubble, got \(shown)")
        guard case let .link(url, title, site, _, _) = shown[0] else { Issue.record("first part is not the card: \(shown[0])"); return }
        #expect(url == "https://github.com/manaflow-ai/cmux")
        #expect(title == "github.com")
        #expect(site == "github.com")
        guard case let .text(text, _) = shown[1] else { Issue.record("second part is not text: \(shown[1])"); return }
        #expect(text == "is this the right repo?")
    }

    @Test func theChiefsURLLineIsACardToo() throws {
        let shown = parts(them, "Here it is:\nhttps://github.com/manaflow-ai/cmux/pull/1")
        try #require(shown.count == 2, "text bubble + card, got \(shown)")
        guard case .text("Here it is:", _) = shown[0], case .link = shown[1] else { Issue.record("got \(shown)"); return }
    }

    @Test func aURLInsideASentenceGetsNoCard() throws {
        let shown = parts(me, "see https://cmux.com for docs")
        try #require(shown.count == 1)
        guard case let .text(text, runs) = shown[0] else { Issue.record("not text: \(shown[0])"); return }
        #expect(text == "see https://cmux.com for docs")
        #expect(runs.contains { $0.link == "https://cmux.com" }, "an underlined link run, no card")
    }

    @Test func aBareURLIsOnlyTheCard() throws {
        let shown = parts(me, "https://cmux.com")
        try #require(shown.count == 1)
        guard case .link = shown[0] else { Issue.record("not a card: \(shown[0])"); return }
    }

    /// The bubble must fit every line after HomeStore replaces a message's
    /// text under the same id (an optimistic send, then the stored text).
    @Test func aTextReplacedInPlaceIsMeasuredAgain() throws {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        let short = Fixture2.item(2, me, "Short", key: "k2")
        p.apply(items: [Fixture2.item(1, them, "Hi"), short], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        let long = "This message is long enough to wrap onto several lines in the Home pane, so a bubble measured for "
            + "the first one-word text would cut it off after its first line and draw the rest outside the bubble."
        p.apply(items: [Fixture2.item(1, them, "Hi"), Fixture2.item(2, me, long, key: "k2")], summary: Fixture2.summary(lastSeq: 2),
                typing: [], hasOlder: false)
        let row = try #require(c.demo.model.rows.first { $0.spec.key == "part:k2:0" })
        let lines = TextLayout.make(long, runs: [], maxWidth: row.spec.metrics.maxTextWidth).lines.count
        #expect(lines >= 3)
        #expect(row.spec.height >= CGFloat(lines) * Fixture.lineHeight, "row \(row.spec.height) pt for \(lines) lines")
    }

    /// The bug's own sequence: a one-line text, then HomeStore's URL-plus-text under the same id.
    @Test func theURLPlusTextReplacementShowsACardAndAFullTextBubble() throws {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        p.apply(items: [Fixture2.item(1, them, "Hi"), Fixture2.item(2, me, "https://github.com/manaflow-ai/cmux", key: "k2")],
                summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        p.apply(items: [Fixture2.item(1, them, "Hi"), Fixture2.item(2, me, Self.urlAndText, key: "k2")],
                summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        let message = try #require(c.store.state.message("k2"))
        try #require(message.parts.count == 2, "card + text bubble, got \(message.parts)")
        let keys = c.demo.model.rows.map(\.spec.key).filter { $0.hasPrefix("part:k2:") }
        #expect(keys == ["part:k2:0", "part:k2:1"])
        let text = try #require(c.demo.model.rows.first { $0.spec.key == "part:k2:1" })
        #expect(text.spec.height >= Fixture.lineHeight)
    }

    /// A tapback on the text bubble of a split message is on HomeStore's one text part.
    @Test func aTapbackOnTheSplitTextIsOnItsHomeStorePart() async throws {
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: 1),
                                    messages: [Fixture2.message(1, them, Self.urlAndText)])
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        let (p, _) = Fixture2.projection(store: store)
        p.start()
        p.react(PartRef(messageId: "k1", partIndex: 1), .tapback("like"))
        var sent = await source.submitted
        for _ in 0..<400 where sent.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
            sent = await source.submitted
        }
        #expect(sent.map(\.op) == [.addReaction(message: MessageID("msg_1"), conversation: Fixture2.id,
                                                reaction: .tapback(.like), partIndex: 0)])
        p.stop()
        store.stop()
    }

    /// The text column follows Messages at every window width (da2b8ae), and a
    /// pane narrower than Messages' 434 pt minimum still has a positive column.
    @Test func theTextColumnFollowsMessagesAndStaysPositiveInANarrowPane() {
        #expect(Metrics(width: 628).maxTextWidth == 358.4)
        #expect(abs(Metrics(width: 434).maxTextWidth - 231.5) < 0.11)
        #expect(abs(Metrics(width: 520).maxTextWidth - 287.8) < 0.11)
        for w in [80, 200, 300, 433] as [CGFloat] {
            #expect(Metrics(width: w).maxTextWidth > 0, "\(w) pt")
            #expect(Metrics(width: w).maxTextWidth <= Metrics(width: 434).maxTextWidth)
        }
    }
}

/// Link previews never request a private or local address (LinkPreviewAddressPolicy).
@Suite struct LinkPreviewAddressPolicyTests {
    @Test func privateAndLocalURLsAreRefused() {
        for url in ["http://localhost:3000/x", "http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.1/", "http://172.20.0.1/",
                    "http://100.89.225.106:18765/status", "http://169.254.169.254/latest/meta-data", "http://[::1]/", "http://[fe80::1]/",
                    "http://[fd00::1]/", "http://[::ffff:127.0.0.1]/", "http://printer.local/", "https://cmux-dev-backend-1.tail137216.ts.net/",
                    "http://intranet/", "ftp://example.com/", "file:///etc/passwd", "https://user:pw@example.com/"] {
            #expect(LinkPreviewAddressPolicy.allowsURL(url) == nil, "\(url)")
        }
    }

    @Test func publicURLsAreAllowed() {
        for url in ["https://github.com/manaflow-ai/cmux", "http://example.com/", "https://1.1.1.1/", "https://[2606:4700:4700::1111]/"] {
            #expect(LinkPreviewAddressPolicy.allowsURL(url) != nil, "\(url)")
        }
        #expect(LinkPreviewAddressPolicy.isPublic([8, 8, 8, 8]))
        #expect(!LinkPreviewAddressPolicy.isPublic([100, 100, 1, 1]))
    }
}
