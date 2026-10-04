import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// A source with no attachment storage (the Mac's local conversation owner
/// today): the send of an attachment fails "Not Delivered", the host hears
/// why, and the reason is readable without a screenshot.
@MainActor
@Suite struct DeliveryReasonTests {
    let conversation = ConversationID("conv_austin")

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() { await Task.yield() }
    }

    @Test func anAttachmentSendToASourceWithoutStorageSaysWhyItWasNotDelivered() async throws {
        let source = NoAttachmentStorageSource(inner: MockHomeSource(options: .immediate))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("l16-delivery-\(UUID().uuidString)")
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
        var notDelivered: [(IdempotencyKey, HomeRejection)] = []
        binding.onSendNotDelivered = { notDelivered.append(($0.key, $1)) }

        let png = try AttachmentFixtures.png(width: 40, height: 30, gray: 0.5)
        let prepared = try await store.prepareAttachment(fileURL: png)
        let intent = try #require(c.sendHosted(text: "", attachments: [HomeOutgoingAttachment(ref: prepared.ref, files: prepared.files)],
                                                from: field))
        await waitUntil { !notDelivered.isEmpty }
        #expect(notDelivered.map(\.0) == [intent.key], "the host hears that this send was not delivered")
        let report = HomeDeliveryReport.pending(store.transcript(for: conversation))
        let row = try #require(report.first { $0.key == intent.key })
        #expect(row.state == "notDelivered")
        #expect(row.reason == "invalid: attachments unsupported", "the reason is readable, not only a red mark")
        #expect(row.attachments == [prepared.ref.hash])
    }
}

/// Forwards everything to the mock owner but has no attachment storage: the
/// `HomeSource` defaults refuse upload and fetch.
struct NoAttachmentStorageSource: HomeSource {
    let inner: MockHomeSource

    func events() async -> AsyncStream<HomeEvent> { await inner.events() }
    func inbox() async throws -> InboxSnapshot { try await inner.inbox() }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await inner.snapshot(of: conversation, tail: tail)
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await inner.history(of: conversation, before: beforeSeq, limit: limit)
    }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await inner.submit(intent) }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await inner.search(query, limit: limit) }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await inner.resolve(contact) }
}
