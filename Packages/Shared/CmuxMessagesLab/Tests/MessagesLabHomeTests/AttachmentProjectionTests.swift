import AppKit
import CmuxHomeCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Lane 16's attachments on MessagesLab's seams: a prepared attachment is
/// MessagesLab's draft chip, Send is one HomeStore send (attachments in
/// order, then the text) with MessagesLab's send transition, bubbles get
/// their pictures from local files or the store without a reflow, upload
/// progress and Cancel Upload follow HomeStore, and a refused send gives the
/// draft back.
@MainActor @Suite(.serialized) struct AttachmentProjectionTests {
    let me = Fixture2.me, them = Fixture2.them

    static func png(_ name: String, width: Int = 1200, height: Int = 900) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// A started HomeStore over the mock owner, its first conversation open.
    private func mockStore() async throws -> (HomeStore, MockHomeSource, ConversationID, ParticipantID) {
        let source = MockHomeSource(options: .immediate)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mlab-att-\(UUID().uuidString)")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        let inbox = try await source.inbox()
        let id = try #require(inbox.conversations.first?.id)
        await store.open(id)
        return (store, source, id, inbox.me.id)
    }

    private func projection(_ store: HomeStore, _ id: ConversationID, _ me: ParticipantID) -> (HomeProjection, ChatController) {
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
        let p = HomeProjection(store: store, conversation: id, me: me, controller: controller)
        p.start()
        return (p, controller)
    }

    @Test func aDraftAttachmentIsMessagesLabsChipAndSendsAttachmentsThenText() async throws {
        let (store, _, id, myID) = try await mockStore()
        defer { store.stop() }
        let (p, c) = projection(store, id, myID)
        defer { p.stop() }
        let photo = try await store.prepareAttachment(fileURL: try Self.png("photo.png"))
        await p.addDraft(photo)
        let chip = try #require(c.store.state.ui.draft.attachments.first)
        #expect(chip.id == photo.ref.hash)
        #expect(chip.kind == "image")
        #expect(chip.asset != nil, "the picture is made before the chip shows, so the bubble has it from the first frame")
        #expect(c.demo.compose.chips.map(\.id) == [photo.ref.hash], "MessagesLab's compose chips")
        c.dispatch(.setDraft("Here"))
        let before = c.store.state.conversation.messages.count
        p.send()
        let local = try #require(c.store.state.conversation.messages.last)
        #expect(c.store.state.conversation.messages.count == before + 1)
        guard case .attachment(let a)? = local.parts.first else { Issue.record("attachment first: \(local.parts)"); return }
        #expect(a.id == photo.ref.hash)
        #expect(local.parts.last?.plainText == "Here")
        #expect(c.store.state.ui.draft.attachments.isEmpty && c.store.state.ui.draft.text.isEmpty)
        let key = try #require(p.aliases.first { $0.value == local.id }?.key)
        await waitUntil { store.transcript(for: id).contains { $0.key == key && $0.seq != nil } }
        let item = try #require(store.transcript(for: id).first { $0.key == key })
        #expect(item.attachmentHashes == [photo.ref.hash] && item.parts.count == 2 && item.parts.last == .text("Here"),
                "one message: the attachment, then the text")
        await waitUntil { p.shown.contains { $0.key == key && $0.seq != nil } }
        #expect(c.store.state.conversation.messages.filter { $0.id == local.id }.count == 1, "the echo only changes the status")
    }

    @Test func aBubbleGetsItsPictureFromTheStoreWithoutAReflow() async throws {
        let (p, c) = Fixture2.projection()
        let file = try Self.png("remote.png", width: 1600, height: 1200)
        let ref = AttachmentRef(hash: "h-remote", name: "remote.png", mimeType: "image/png", byteCount: 10, width: 1600, height: 1200)
        let asked = Recorder()
        p.media.fetch = { ref, variant in
            await asked.add("\(ref.hash) \(variant)")
            return file
        }
        let incoming = TranscriptItem(key: IdempotencyKey("img"), seq: 4, author: them, parts: [.attachment(ref)],
                                      createdAt: Fixture2.start.addingTimeInterval(200), delivery: .committed, messageID: MessageID("m4"))
        p.apply(items: Fixture2.history(3) + [incoming], summary: Fixture2.summary(lastSeq: 4), typing: [], hasOlder: false)
        let row0 = try #require(c.demo.model.rows.first { RowBuilder.owner($0.spec.key) == "img" })
        await p.media.settled()
        await waitUntil { p.media.asset("h-remote") != nil }
        guard case .attachment(let a)? = c.store.state.message("img")?.parts.first else { Issue.record("no attachment"); return }
        #expect(a.asset != nil, "the picture reached MessagesLab's part")
        let row1 = try #require(c.demo.model.rows.first { RowBuilder.owner($0.spec.key) == "img" })
        #expect(row0.spec.height == row1.spec.height && row0.spec.gap == row1.spec.gap, "no reflow when the bytes arrive")
        #expect(await asked.values == ["h-remote thumbnail(maxPixel: 1024)"], "an image asks for a thumbnail, once")
    }

    @Test func aVideoShowsItsPosterAndNeverFetchesTheMovieForAFrame() async throws {
        let (p, c) = Fixture2.projection()
        let poster = try Self.png("poster.png", width: 640, height: 360)
        let ref = AttachmentRef(hash: "h-video", name: "clip.mov", mimeType: "video/quicktime", byteCount: 10, width: 640, height: 360,
                                durationMs: 2_000)
        let asked = Recorder()
        p.media.fetch = { _, variant in
            await asked.add("\(variant)")
            return poster
        }
        let item = TranscriptItem(key: IdempotencyKey("vid"), seq: 4, author: them, parts: [.attachment(ref)],
                                  createdAt: Fixture2.start.addingTimeInterval(200), delivery: .committed, messageID: MessageID("m4"))
        p.apply(items: Fixture2.history(3) + [item], summary: Fixture2.summary(lastSeq: 4), typing: [], hasOlder: false)
        await waitUntil { p.media.asset("h-video") != nil }
        guard case .attachment(let a)? = c.store.state.message("vid")?.parts.first else { Issue.record("no attachment"); return }
        #expect(a.kind == "video" && a.poster != nil && a.asset == nil, "MessagesLab draws poster ?? asset: the poster, never the movie")
        #expect(a.durationSeconds == 2)
        #expect(await asked.values == ["poster"])
    }

    @Test func fileRowsShowUploadProgressAndCancelUploadFollowsTheStore() async throws {
        let (p, c) = Fixture2.projection()
        let pdf = AttachmentRef(hash: "h-pdf", name: "plan.pdf", mimeType: "application/pdf", byteCount: 2_000)
        var uploading = TranscriptItem(key: IdempotencyKey("up"), seq: nil, author: me, parts: [.attachment(pdf)],
                                       createdAt: Fixture2.start.addingTimeInterval(300), delivery: .sending,
                                       attachmentProgress: [pdf.hash: 0.43])
        let waiting = TranscriptItem(key: IdempotencyKey("wait"), seq: nil, author: me, parts: [.text("queued")],
                                     createdAt: Fixture2.start.addingTimeInterval(301), delivery: .sending)
        p.apply(items: Fixture2.history(2) + [uploading, waiting], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        guard case .attachment(let a)? = c.store.state.message("up")?.parts.first, case .uploading(let shown) = a.transfer else {
            Issue.record("a file row shows MessagesLab's upload bar"); return
        }
        #expect(shown == 0.42, "2% steps")
        #expect(p.canCancelSend("up"), "an upload can be cancelled")
        #expect(!p.canCancelSend("wait"), "a send with no upload in flight cannot")
        var cancelled: [IdempotencyKey] = []
        p.onCancelSend = { cancelled.append($0); return true }
        p.cancelSend("up")
        p.cancelSend("wait")
        #expect(cancelled == [IdempotencyKey("up")])
        uploading.attachmentProgress = [:]
        uploading.delivery = .notDelivered(.ownerUnreachable)
        p.apply(items: Fixture2.history(2) + [uploading, waiting], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        guard case .attachment(let done)? = c.store.state.message("up")?.parts.first else { Issue.record("no attachment"); return }
        #expect(done.transfer == .done)
        #expect(p.canCancelSend("up"), "a failed send can be cancelled")
    }

    @Test func aSendTheStoreRefusesForItsAttachmentGivesTheDraftBack() async throws {
        let (store, _, id, myID) = try await mockStore()
        defer { store.stop() }
        let (p, c) = projection(store, id, myID)
        defer { p.stop() }
        var refusals: [HomeAttachmentError] = []
        p.onAttachmentRefusal = { refusals.append($0) }
        let big = LocalAttachment(ref: AttachmentRef(hash: "h-big", name: "huge.png", mimeType: "image/png", byteCount: 200_000_000,
                                                     width: 10, height: 10),
                                  fileURL: try Self.png("huge.png", width: 10, height: 10))
        await p.addDraft(big)
        c.dispatch(.setDraft("Too big"))
        let before = c.store.state.conversation.messages.count
        p.send()
        await waitUntil { !refusals.isEmpty }
        #expect(refusals.count == 1)
        if case .tooLarge? = refusals.first {} else { Issue.record("tooLarge, got \(refusals)") }
        #expect(c.store.state.conversation.messages.count == before, "the local message goes")
        #expect(c.store.state.ui.draft.text == "Too big")
        #expect(c.store.state.ui.draft.attachments.map(\.id) == ["h-big"], "the chip is back")
        #expect(p.draftAttachments.map(\.ref.hash) == ["h-big"])
    }
}

actor Recorder {
    private(set) var values: [String] = []
    func add(_ v: String) { values.append(v) }
}
