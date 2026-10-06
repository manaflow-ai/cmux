import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Sender-side link previews (iMessage's rule, coordinator decision 2026-10-06):
/// the Mac fetches a preview only for a link it sends or a card the user taps,
/// always through MessagesLab's LinkGuard; a received card never fetches by itself.
@MainActor @Suite(.serialized) struct LinkPreviewPolicyTests {
    let me = Fixture2.me, them = Fixture2.them

    private func projection(_ store: HomeStore? = nil) -> (HomeProjection, ChatController, HomeLinkPreviews) {
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
        let previews = HomeLinkPreviews(LinkPreviews())
        let store = store ?? HomeStore(source: ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(), messages: []))
        let p = HomeProjection(store: store, conversation: Fixture2.id, me: me, controller: controller, linkPreviews: previews)
        return (p, controller, previews)
    }

    @Test func aReceivedLinkNeverFetchesWithoutATap() throws {
        let (p, c, previews) = projection()
        let first = [Fixture2.item(1, me, "hi", key: "k1")]
        p.apply(items: first, summary: Fixture2.summary(lastSeq: 1), typing: [], hasOlder: false)
        p.apply(items: first + [Fixture2.item(2, them, "https://example.com/report\nhere it is", key: "turn:s1:2")],
                summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        #expect(previews.requested.isEmpty, "a received card fetched: \(previews.requested)")
        let card = try #require(c.store.state.message(HomeMapping.rowSafe("turn:s1:2"))?.parts.first)
        guard case let .link(_, title, site, image, _) = card else { Issue.record("not a card: \(card)"); return }
        #expect(title == "example.com" && site == "example.com" && image == nil, "the domain-only card")
    }

    @Test func aTapFetchesThroughLinkGuard() async throws {
        let (p, _, previews) = projection()
        p.apply(items: [Fixture2.item(1, them, "http://127.0.0.1:8080/admin", key: "turn:s1:1")],
                summary: Fixture2.summary(lastSeq: 1), typing: [], hasOlder: false)
        #expect(previews.requested.isEmpty)
        let url = "http://127.0.0.1:8080/admin"
        p.linkTapped(PartRef(messageId: HomeMapping.rowSafe("turn:s1:1"), partIndex: 0), url: url)
        #expect(previews.requested == [url])
        await waitUntil { previews.previews.lastRefusal[url] != nil }
        #expect(previews.previews.lastRefusal[url] != nil, "LinkGuard refused the private address")
    }

    @Test func mySendFetchesItsPreview() async throws {
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: 0), messages: [])
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        let (p, c, previews) = projection(store)
        p.start()
        c.dispatch(.setDraft("https://10.0.0.1/doc\nlook"))
        p.send()
        #expect(previews.requested == ["https://10.0.0.1/doc"], "the sender makes the preview")
        p.stop()
        store.stop()
    }

    @Test func linkGuardRefusesPrivateAndLocalURLs() {
        for url in ["http://localhost:3000/", "http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.1/", "http://100.89.225.106/",
                    "http://169.254.169.254/latest", "http://[::1]/", "http://[fd00::1]/", "http://printer.local/", "http://intranet/",
                    "https://example.com:8443/", "ftp://example.com/"] {
            #expect(LinkGuard.checkURL(URL(string: url)!) != nil, "\(url)")
        }
        #expect(LinkGuard.checkURL(URL(string: "https://github.com/manaflow-ai/cmux")!) == nil)
    }
}
