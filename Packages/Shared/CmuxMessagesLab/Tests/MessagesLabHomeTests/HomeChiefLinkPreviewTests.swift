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

    struct Pane { let window: NSWindow; let controller: ChatController }

    private func pane(links: @escaping HomeMapping.Links = { _ in nil }) -> Pane {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.chief, kind: .agent, displayName: "Chief", agentClass: .chief),
                      CmuxHomeCore.Participant(id: Self.friend, kind: .human, displayName: "Friend"),
                      CmuxHomeCore.Participant(id: Self.helper, kind: .agent, displayName: "Helper")]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ n: Int, _ author: ParticipantID, _ text: String) -> TranscriptItem {
            TranscriptItem(key: IdempotencyKey("k\(n)"), seq: Seq(UInt64(n)), author: author, parts: [.text(text)],
                           createdAt: base.addingTimeInterval(Double(n)), delivery: .committed, messageID: MessageID("msg_\(n)"))
        }
        let items = [item(1, Self.friend, "Look at \(Self.friends) later"),
                     item(2, Self.helper, "Helper read \(Self.helpers) for you."),
                     item(3, Self.me, "Did you see \(Self.mine) today?\n\(Self.sole)"),
                     item(4, Self.chief, Self.chiefText)]
        let summary = ConversationSummary(id: ConversationID("conv_link_cards"), title: "Chief", participants: people, lastSeq: 4,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        core.links = links
        let (conv, w) = core.install(ConversationID("conv_link_cards"), items: items, summary: summary)
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
        pane.controller.store?.state.conversation.messages.first { $0.id == "k\(n)" }?.parts ?? []
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
        // My sentence's link gets a card; the URL-only line keeps its one card (no second card for it).
        #expect(cardURLs(parts(pane, 3)) == [Self.mine, Self.sole])
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
        let items = (1 ... 4).map { n in
            TranscriptItem(key: IdempotencyKey("k\(n)"), seq: Seq(UInt64(n)), author: [Self.friend, Self.helper, Self.me, Self.chief][n - 1],
                           parts: [], createdAt: Date(timeIntervalSince1970: 1_800_000_000), delivery: .committed, messageID: MessageID("msg_\(n)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_link_cards"), title: "Chief", participants: [
            CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: Self.chief, kind: .agent, displayName: "Chief", agentClass: .chief),
            CmuxHomeCore.Participant(id: Self.friend, kind: .human, displayName: "Friend"),
            CmuxHomeCore.Participant(id: Self.helper, kind: .agent, displayName: "Helper"),
        ], lastSeq: 4, createdAt: .distantPast, updatedAt: .distantPast, readCursors: [:], readCursorTimes: [:])
        let urls = HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [Self.docs], limit: 8) { item in
            store.state.message(item.key.rawValue)?.parts ?? []
        }
        // Newest first; an asked URL is not asked again; a friend's and another agent's cards never fetch.
        #expect(urls == [Self.pr, Self.mine, Self.sole])
        #expect(HomeProjection.previewableCardURLs(items, summary: summary, me: Self.me, asked: [], limit: 2) { item in
            store.state.message(item.key.rawValue)?.parts ?? []
        }.count == 2)

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
