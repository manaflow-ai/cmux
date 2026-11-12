@testable import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// The controller wired to a real `HomeStore` over the mock owner: a hosted
/// send with an attachment goes through `HomeStore.send` (upload, then
/// message.send with the same key), the bubble shows the local file and an
/// upload ring at once, and progress lays nothing out.
@MainActor
@Suite struct BoundAttachmentTests {
    let conversation = ConversationID("conv_austin")

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() { await Task.yield() }
    }

    @Test func aBoundSendUploadsThroughTheStoreWithARingAndNoLayoutPass() async throws {
        let source = MockHomeSource(options: .immediate)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("home-bound-\(UUID().uuidString)")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let c = HomeController(conversation: conversation, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        c.resize(to: CGSize(width: 628, height: 900))
        let field = CGRect(x: 51, y: 859, width: 526, height: 30)
        c.setHostedField(field)
        let binding = HomeStoreBinding(store: store, controller: c)
        defer { binding.stop() }

        let png = try AttachmentFixtures.png(width: 800, height: 600, gray: 0.6)
        let prepared = try await store.prepareAttachment(fileURL: png)
        #expect(prepared.ref.width == 800)
        await source.setUploadsPaused(true)
        let intent = try #require(c.sendHosted(text: "look", attachments: [HomeOutgoingAttachment(ref: prepared.ref, files: prepared.files)],
                                                from: field))
        let key = "part:\(intent.key.rawValue):0"
        await waitUntil { c.scene.visible[key] != nil && c.scene.uploadProgress[prepared.ref.hash] != nil }
        let row = try #require(c.scene.visible[key], "the pending send shows at once")
        #expect(!row.progressRing.isHidden, "the upload ring shows while the bytes upload")
        #expect(c.scene.morphs[key] != nil, "the attachment flies into its bubble")
        await c.attachmentsSettled()
        #expect(row.mediaImage.contents != nil, "the local copy shows before the upload ends")
        let commits = c.scene.commitCount

        await source.setUploadsPaused(false)
        await waitUntil { store.transcript(for: self.conversation).last?.delivery == .committed && c.scene.uploadProgress.isEmpty }
        #expect(store.transcript(for: conversation).last?.parts == [.attachment(prepared.ref), .text("look")])
        #expect(row.progressRing.isHidden, "the ring goes when the upload ends")
        #expect(c.scene.commitCount <= commits + 1, "progress steps lay nothing out (only the commit's delivery change)")
        #expect(await source.uploadCalls == [prepared.ref.hash])
    }

    private func bound() async throws -> (HomeStore, MockHomeSource, HomeController, HomeStoreBinding) {
        let source = MockHomeSource(options: .immediate)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("home-bound-\(UUID().uuidString)")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let c = HomeController(conversation: conversation, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        c.resize(to: CGSize(width: 628, height: 900))
        c.setHostedField(CGRect(x: 51, y: 859, width: 526, height: 30))
        return (store, source, c, HomeStoreBinding(store: store, controller: c))
    }

    @Test func aBackgroundRefusalFromTheStoreReachesTheHost() async throws {
        let (store, _, _, binding) = try await bound()
        defer { binding.stop() }
        var refused: [HomeRejection] = []
        binding.onRefusal = { _, rejection in refused.append(rejection) }
        let intent = HomeIntent(op: .sendMessage(conversation: conversation, parts: [.text("resumed")]))
        // How the store reports a refusal of a resumed upload or a resend.
        store.reportRefusal(intent, .notAuthorized)
        #expect(refused == [.notAuthorized])
    }

    @Test func anUploadingSendCanBeCancelledAndLeavesTheTranscript() async throws {
        let (store, source, c, binding) = try await bound()
        defer { binding.stop() }
        let png = try AttachmentFixtures.png(width: 400, height: 300, gray: 0.5)
        let prepared = try await store.prepareAttachment(fileURL: png)
        await source.setUploadsPaused(true)
        let intent = try #require(c.sendHosted(text: "", attachments: [HomeOutgoingAttachment(ref: prepared.ref, files: prepared.files)],
                                                from: CGRect(x: 51, y: 859, width: 526, height: 30)))
        await waitUntil { !(store.transcript(for: self.conversation).last?.attachmentProgress.isEmpty ?? true) }
        let item = try #require(store.transcript(for: conversation).last)
        #expect(item.key == intent.key)
        await waitUntil { c.cancellableSend(item.key) != nil }  // the binding delivers store changes on the next main-actor turn
        #expect(c.cancellableSend(item.key) == true, "an uploading send offers Cancel")
        #expect(binding.cancelSend(item.key))
        await waitUntil { !store.transcript(for: self.conversation).contains { $0.key == intent.key } }
        #expect(!store.transcript(for: conversation).contains { $0.key == intent.key }, "a cancelled send leaves the transcript")
        await source.setUploadsPaused(false)
    }

    @Test func anUnansweredOpReachesTheHostOfItsConversation() async throws {
        let (store, _, _, binding) = try await bound()
        defer { binding.stop() }
        var unanswered: [IdempotencyKey] = []
        binding.onUnanswered = { unanswered.append($0.key) }
        // How the store reports an op that ran out of resends.
        let report = store.reportUnanswered
        let mine = HomeIntent(op: .setReadCursor(conversation: conversation, seq: 3))
        let other = HomeIntent(op: .setReadCursor(conversation: ConversationID("conv_other"), seq: 3))
        report(mine)
        report(other)
        #expect(unanswered == [mine.key], "only this conversation's ops")
    }
}
