import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Issue 38178: in the Chief chat a link shows the pointing hand on hover, and links show
/// Messages-style preview cards (title, site, picture). A real `ChatController` over a loaded
/// conversation in an offscreen window, mapped by the same `ProjectionCore` the live view uses.
@MainActor @Suite(.serialized) struct HomeChiefLinkPreviewTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
    static let friend = ParticipantID("user_friend"), helper = ParticipantID("agent_helper")
    static let pr = "https://example.com/pull/2", docs = "https://docs.example.com/guide"
    static let mine = "https://news.example.org/story", sole = "https://example.net/alone"
    static let friends = "https://friend.example.com/page", helpers = "https://helper.example.com/page"
    static let chiefText = "The fix is in [PR 2](\(pr)); the guide is at \(docs) if you want it."
    static let gitHubPR = "https://github.com/manaflow-ai/cmux/pull/38178", bot = "https://bot.example.com/page"
    static let gitHubRun = "https://github.com/manaflow-ai/cmux/actions/runs/42"
    static let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                         CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
                         CmuxHomeCore.Participant(id: friend, kind: .human, displayName: "Friend"),
                         CmuxHomeCore.Participant(id: helper, kind: .agent, displayName: "Helper")]
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let summary = ConversationSummary(id: ConversationID("conv_link_cards"), title: "Chief", participants: people, lastSeq: 6,
                                             createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])

    static func item(_ n: Int, _ author: ParticipantID, _ text: String, key: String? = nil) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey(key ?? "k\(n)"), seq: Seq(UInt64(n)), author: author, parts: [.text(text)],
                       createdAt: base.addingTimeInterval(Double(n)), delivery: .committed, messageID: MessageID("msg_\(n)"))
    }

    /// A friend's, another agent's, mine, the Chief's, the Chief's with a file name and a GitHub link,
    /// and an agent's message sent through my CLI (authored as me, marked `agent~`).
    static let items = [item(1, friend, "Look at \(friends) later"),
                        item(2, helper, "Helper read \(helpers) for you."),
                        item(3, me, "Did you see \(mine) today?\n\(sole)"),
                        item(4, chief, chiefText),
                        item(5, chief, "I updated README.md for \(gitHubPR); CI is [here](\(gitHubRun))."),
                        item(6, me, "[from Grok bot] I read this for you\n\(bot)", key: "agent~grok-1")]

    struct Pane { let window: NSWindow; let controller: ChatController }

    private func pane(links: @escaping HomeMapping.Links = { _ in nil }) -> Pane {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        var core = ProjectionCore(me: Self.me)
        core.links = links
        let (conv, w) = core.install(ConversationID("conv_link_cards"), items: Self.items, summary: Self.summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 560, height: 900)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return Pane(window: window, controller: controller)
    }

    private func parts(_ pane: Pane, _ n: Int) -> [Part] {
        let item = Self.items[n - 1]
        return pane.controller.store?.state.conversation.messages.first { $0.id == HomeMapping.id(item, aliases: [:]) }?.parts ?? []
    }

    private func cardURLs(_ parts: [Part]) -> [String] {
        parts.compactMap { if case let .link(url, _, _, _, _) = $0 { return url }; return nil }
    }

    @Test func aLinkInASentenceGetsItsCardAfterItsBubble() throws {
        let pane = pane()
        // The Chief's Markdown link and bare URL: one bubble, then a card for each, in order.
        let chief = parts(pane, 4)
        #expect(chief.count == 3)
        if case .text = chief.first {} else { Issue.record("the Chief's text bubble comes first: \(chief)") }
        #expect(cardURLs(chief) == [Self.pr, Self.docs])
        // Settled with no fetched preview: the domain card.
        if case let .link(_, title, site, _, _)? = chief.last { #expect(title == "docs.example.com" && site == "docs.example.com") }
        // A person's bubbles keep Messages' rule: my sentence's link is no card, my URL-only line is one.
        #expect(cardURLs(parts(pane, 3)) == [Self.sole])
        // A file name the detector reads as a domain ("README.md") is no card; a GitHub pull request's
        // card is titled from its URL (a private repository's page needs sign-in, so it is never fetched).
        let five = parts(pane, 5)
        #expect(cardURLs(five) == [Self.gitHubPR, Self.gitHubRun])
        if case let .link(_, title, site, _, _)? = five.dropLast().last { #expect(title == "manaflow-ai/cmux#38178" && site == "github.com") }
        withExtendedLifetime(pane.window) {}
    }

    @Test func aFetchedPreviewFillsTheCardWithTitleSiteAndPicture() throws {
        let picture = "file:///tmp/preview.png"
        let pane = pane(links: { $0 == Self.pr ? LinkMetadata(title: "Fix the thing", site: "example.com", image: picture) : nil })
        let card = try #require(parts(pane, 4).first { if case let .link(url, _, _, _, _) = $0 { return url == Self.pr }; return false })
        guard case let .link(_, title, site, image, _) = card else { Issue.record("not a card"); return }
        #expect(title == "Fix the thing" && site == "example.com" && image == picture)
        withExtendedLifetime(pane.window) {}
    }

    @Test func myCardsAndTheChiefsFetchAndOthersDoNot() throws {
        let pane = pane()
        let store = try #require(pane.controller.store)
        let items = Self.items, summary = Self.summary
        func shown(_ item: TranscriptItem) -> [Part]? { store.state.message(HomeMapping.id(item, aliases: [:]))?.parts }
        var scanned: Set<IdempotencyKey> = []
        let urls = HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [Self.docs], scanned: &scanned, limit: 8, parts: shown)
        // Newest first; an asked URL is not asked again; a friend's, another agent's and an agent's
        // message through my CLI never fetch; a GitHub card (local title, or a page that needs sign-in) is not fetched.
        #expect(urls == [Self.pr, Self.sole])
        // Every message was looked at once: the next pass asks nothing and looks at none of them again.
        #expect(scanned == Set(items.map(\.key)))
        #expect(HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [], scanned: &scanned, limit: 8, parts: { _ in
            Issue.record("a scanned message was looked at again"); return []
        }).isEmpty)
        // A pass stops at its limit; the message it stopped in is looked at again in the next pass.
        var partly: Set<IdempotencyKey> = []
        #expect(HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [], scanned: &partly, limit: 1, parts: shown) == [Self.pr])
        #expect(!partly.contains(items[3].key))
        #expect(HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [Self.pr], scanned: &partly, limit: 1, parts: shown) == [Self.docs])
        #expect(!cardURLs(shown(items[5]) ?? []).isEmpty, "the agent's message shows its card, domain only")

        // The gate: a shown card the projection allowed fetches; any other URL is refused with no request.
        var loaded: [String] = []
        let gate = HomeLinkPreviews(fetch: { url, done in loaded.append(url); done(LinkMetadata(title: "T", site: "s", image: nil)) })
        var refused = false
        gate.fetch(Self.friends) { refused = $0 == nil }
        gate.allowShown(Self.pr)
        var answer: LinkMetadata?
        gate.fetch(Self.pr) { answer = $0 }
        #expect(refused && loaded == [Self.pr] && answer?.title == "T" && gate.cached(Self.pr)?.title == "T")
        withExtendedLifetime(pane.window) {}
    }

    /// A fetched title reads as the page shows it: swift.org's card said "Redirecting&hellip;".
    @Test func aCardTitleDecodesItsEntities() {
        #expect(LinkPreviews.decode("Redirecting&hellip;") == "Redirecting…")
        #expect(LinkPreviews.decode("Swift &#8212; Docs &#x2019;26 &mdash; A&amp;B") == "Swift — Docs ’26 — A&B")
        // One pass: an escaped entity stays escaped; an unknown or bare ampersand is kept as written.
        #expect(LinkPreviews.decode("a &amp;lt; b &bogus; & c &#xZZ;") == "a &lt; b &bogus; & c &#xZZ;")
    }

    @Test func theHandShowsOverALinkAndTheArrowOverText() throws {
        let pane = pane()
        let controller = pane.controller
        let document = controller.host.scrollView.document
        #expect(document.controller === controller)
        let b = controller.host.bounds
        var onLink: CGPoint?, onText: CGPoint?
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                guard let hit = controller.demo?.hit(p), case .text = hit.row.part else { continue }
                if controller.linkURL(at: p)?.absoluteString == Self.pr { onLink = onLink ?? p } else if controller.linkURL(at: p) == nil { onText = onText ?? p }
            }
        }
        let link = try #require(onLink, "no point over the Chief's Markdown link")
        let text = try #require(onText, "no point over plain text")
        document.updateLinkCursor(at: controller.host.convert(link, to: nil), always: true)
        #expect(document.overLink)
        #expect(NSCursor.current == NSCursor.pointingHand)
        document.updateLinkCursor(at: controller.host.convert(text, to: nil), always: false)
        #expect(!document.overLink)
        #expect(NSCursor.current == NSCursor.arrow)
        withExtendedLifetime(pane.window) {}
    }
}
