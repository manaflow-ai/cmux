import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// iMessage's link previews on the Home path (coordinator decision
/// 2026-10-06): the SENDER attaches the preview it fetched to the message
/// (`link_preview` parts, the picture as its own uploaded record), and a
/// receiver renders from the part without fetching the URL.
@MainActor @Suite(.serialized) struct LinkPreviewSendTests {
    let me = Fixture2.me, them = Fixture2.them
    static let draft = "https://github.com/manaflow-ai/cmux\nis this the right repo?"
    static let url = "https://github.com/manaflow-ai/cmux"

    /// A started store over the scripted owner (it records uploads and submits).
    private func started() async -> (HomeStore, ScriptedSource) {
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: 0), messages: [])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mlab-link-\(UUID().uuidString)")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        return (store, source)
    }

    /// A projection whose link previews answer `meta` without the network.
    private func projection(_ store: HomeStore, answer meta: LinkMetadata?) -> (HomeProjection, ChatController, HomeLinkPreviews) {
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
        let previews = HomeLinkPreviews(LinkPreviews(), fetch: { _, done in done(meta) })
        let p = HomeProjection(store: store, conversation: Fixture2.id, me: me, controller: controller, linkPreviews: previews)
        return (p, controller, previews)
    }

    private func sendDraft(_ p: HomeProjection, _ c: ChatController, _ source: ScriptedSource) async throws -> HomeIntent {
        p.start()
        c.dispatch(.setDraft(Self.draft))
        p.send()
        #expect(c.demo.morphs.count == 1, "the send morph flies at the press")
        let local = try #require(c.store.state.conversation.messages.last)
        #expect(local.parts.count == 2, "MessagesLab's card and text bubble")
        await waitFor { await source.submitted.count == 1 }
        return try #require(await source.submitted.first)
    }

    @Test func mySendAttachesThePreviewAndUploadsItsPicture() async throws {
        let (store, source) = await started()
        defer { store.stop() }
        let og = try AttachmentProjectionTests.png("og.png", width: 1200, height: 630)
        let (p, c, _) = projection(store, answer: LinkMetadata(title: "manaflow-ai/cmux", site: "github.com", image: og.absoluteString))
        defer { p.stop() }
        let sent = try await sendDraft(p, c, source)
        let uploads = await source.uploads
        let picture = try #require(uploads.first)
        #expect(uploads.count == 1, "the preview picture is its own record")
        #expect(picture.mimeType == "image/jpeg" && picture.byteCount <= 512_000)
        let image = AttachmentDerivedImage(hash: picture.hash, mimeType: picture.mimeType, byteCount: picture.byteCount)
        #expect(sent.op == .sendMessage(conversation: Fixture2.id, parts: [
            .linkPreview(LinkPreview(url: Self.url, title: "manaflow-ai/cmux", site: "github.com", image: image)),
            .text("is this the right repo?"),
        ]))
        #expect(p.aliases[sent.key] != nil, "the local message keeps its alias: the echo only changes its status")
    }

    /// A failed fetch sends the card with its URL only (iMessage sends the
    /// URL; every receiver shows the domain card, as the sender does).
    @Test func aFailedFetchSendsTheURLOnly() async throws {
        let (store, source) = await started()
        defer { store.stop() }
        let (p, c, _) = projection(store, answer: nil)
        defer { p.stop() }
        let sent = try await sendDraft(p, c, source)
        #expect(await source.uploads.isEmpty)
        #expect(sent.op == .sendMessage(conversation: Fixture2.id, parts: [
            .linkPreview(LinkPreview(url: Self.url)), .text("is this the right repo?"),
        ]))
    }

    @Test func aReceivedPreviewRendersFromItsPartWithoutFetching() async throws {
        let (store, _) = await started()
        defer { store.stop() }
        let (p, c, previews) = projection(store, answer: LinkMetadata(title: "fetched", site: "fetched", image: nil))
        defer { p.stop() }
        let picture = try AttachmentProjectionTests.png("poster.png", width: 600, height: 315)
        let fetched = FetchLog()
        p.media.fetch = { ref, _ in await fetched.add(ref.hash); return picture }
        let image = AttachmentDerivedImage(hash: String(repeating: "a", count: 64), mimeType: "image/jpeg", byteCount: 40_000)
        let item = TranscriptItem(key: IdempotencyKey("turn:s1:2"), seq: 2, author: them,
                                  parts: [.linkPreview(LinkPreview(url: Self.url, title: "manaflow-ai/cmux", site: "github.com", image: image)),
                                          .text("is this the right repo?")],
                                  createdAt: Fixture2.start.addingTimeInterval(60), delivery: .committed, messageID: MessageID("msg_2"))
        let first = [Fixture2.item(1, me, "hi", key: "k1")]
        p.apply(items: first, summary: Fixture2.summary(lastSeq: 1), typing: [], hasOlder: false)
        p.apply(items: first + [item], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        let id = HomeMapping.rowSafe("turn:s1:2")
        let parts = try #require(c.store.state.message(id)?.parts)
        #expect(parts.count == 2, "the text part adds no second card")
        guard case let .link(url, title, site, _, _) = parts[0] else { Issue.record("not a card: \(parts[0])"); return }
        #expect(url == Self.url && title == "manaflow-ai/cmux" && site == "github.com")
        await p.media.settled()
        guard case let .link(_, _, _, shown, _)? = c.store.state.message(id)?.parts.first else { Issue.record("no card"); return }
        #expect(shown != nil, "the attached picture, fetched from the owner by its hash, fills the card")
        #expect(await fetched.hashes == [image.hash])
        #expect(previews.requested.isEmpty, "a received card never fetches its URL: \(previews.requested)")
    }
}

actor FetchLog {
    private(set) var hashes: [String] = []
    func add(_ hash: String) { hashes.append(hash) }
}
