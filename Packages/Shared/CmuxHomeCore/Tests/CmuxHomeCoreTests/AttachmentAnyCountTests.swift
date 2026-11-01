import Foundation
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

// Leo, 2026-10-26: "why the FUCK SHOULD THERE BE A FUCKING SIZE CAP ANYWAYS ... I ALREADY SAID WE NEED
// ARBITARRILY LARGE FILES OF ANY TYPE". A send with more files than the owner's parts per message
// (`HomeAttachmentPolicy.maxParts`, cmux-conversation `MAX_PARTS`) was refused as `tooManyParts`, and
// the native composer refused the 16th file. Now the send goes as several messages, in order.

@Suite struct AttachmentMessageGroupTests {
    @Test(arguments: [0, 1, 15, 16, 17, 64, 65, 1000])
    func anyNumberOfFilesSplitsWithinThePartLimit(count: Int) {
        let files = Array(0..<count)
        for extra in [0, 1] {
            let groups = HomeAttachmentPolicy.messageGroups(files, extraParts: extra)
            #expect(groups.flatMap { $0 } == files)
            #expect(groups.first.map { $0.count + extra <= HomeAttachmentPolicy.maxParts } == true)
            #expect(groups.allSatisfy { $0.count <= HomeAttachmentPolicy.maxParts })
            #expect(groups.dropFirst().allSatisfy { !$0.isEmpty })
        }
    }
}

@Suite(.timeLimit(.minutes(3))) struct AttachmentAnyCountSendTests {
    let conversation = ConversationID("conv_austin")

    @MainActor func started() async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }
        return (store, source)
    }

    /// The native composer's send (MessagesLab `HomeProjection`): its pieces in the order typed,
    /// text between files, through `send(conversation:parts:uploads:)`.
    @MainActor @Test func seventeenFilesAroundTextSendThroughThePartsOverloadInOrder() async throws {
        let (store, source) = try await started()
        var files: [LocalAttachment] = []
        for index in 0..<17 {
            files.append(try await store.prepareAttachment(data: Data("piece \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        let parts: [MessagePart] = files.prefix(8).map { .attachment($0.ref) } + [.text("between")]
            + files.dropFirst(8).map { .attachment($0.ref) }
        try await store.send(conversation: conversation, parts: parts, uploads: files)
        await waitUntil { store.log.isEmpty }

        let hashes = Set(files.map(\.ref.hash))
        let sent = try await source.snapshot(of: conversation, tail: 20).messages.filter { message in
            message.parts.contains { if case .attachment(let ref) = $0 { hashes.contains(ref.hash) } else { false } }
        }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.parts.count <= HomeAttachmentPolicy.maxParts })
        // The owner may restate a part's stored type and size: compare what each part is.
        func shape(_ part: MessagePart) -> String {
            switch part {
            case .attachment(let ref): "file:" + ref.hash
            case .text(let text, _): "text:" + text
            default: "other"
            }
        }
        #expect(sent.flatMap(\.parts).map(shape) == parts.map(shape))
    }

    /// Review finding: a later message of the send went on after an earlier one failed, so it
    /// committed first and the retry put the failed one after it. The middle one fails here: the
    /// last one waits, and after the retry the owner holds all three in the order sent.
    @MainActor @Test func aFailedMiddleMessageHoldsTheRestUntilItsRetryCommits() async throws {
        let (store, source) = try await started()
        var files: [LocalAttachment] = []
        for index in 0..<40 {
            files.append(try await store.prepareAttachment(data: Data("chunk \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        await source.failNextUpload(hash: files[20].ref.hash, with: .invalid("attachment_upload_failed"), times: 1)
        _ = try? await store.send(conversation: conversation, text: "", attachments: files)
        await waitUntil { store.log.entries.contains { if case .failed = $0.state { true } else { false } } }
        for _ in 0..<500 { await Task.yield() }

        let hashes = Set(files.map(\.ref.hash))
        func committed() async throws -> [[String]] {
            try await source.snapshot(of: conversation, tail: 20).messages.map { message in
                message.parts.compactMap { if case .attachment(let ref) = $0, hashes.contains(ref.hash) { ref.hash } else { nil } }
            }.filter { !$0.isEmpty }
        }
        #expect(try await committed() == [files[0..<16].map(\.ref.hash)], "only the first message, never the third before the second")
        let failed = try #require(store.log.entries.first { if case .failed = $0.state { true } else { false } }?.intent.key)
        #expect(store.log.entries.count == 2, "the failed message and the held one stay")

        try await store.retry(failed)
        await waitUntil { store.log.isEmpty }
        #expect(try await committed() == [files[0..<16].map(\.ref.hash), files[16..<32].map(\.ref.hash), files[32..<40].map(\.ref.hash)])
    }

    /// Review finding: a split send whose messages were all cancelled left its chain behind, and a
    /// later split send that reused its first key then stalled after its first message.
    @MainActor @Test func aReusedKeyAfterACancelledSplitSendStillSendsEveryMessage() async throws {
        let (store, source) = try await started()
        var files: [LocalAttachment] = []
        for index in 0..<20 {
            files.append(try await store.prepareAttachment(data: Data("reuse \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        let key = IdempotencyKey("reused-split-send")
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        _ = try? await store.send(conversation: conversation, text: "", attachments: files, key: key)
        for entry in store.log.entries { #expect(store.cancelSend(entry.intent.key)) }
        #expect(store.log.isEmpty)
        await source.setOnline(true)
        await waitUntil { store.isOnline }

        try await store.send(conversation: conversation, text: "", attachments: files, key: key)
        await waitUntil { store.log.isEmpty }
        let hashes = Set(files.map(\.ref.hash))
        let sent = try await source.snapshot(of: conversation, tail: 20).messages.filter { message in
            message.parts.contains { if case .attachment(let ref) = $0 { hashes.contains(ref.hash) } else { false } }
        }
        #expect(sent.count == 2)
    }

    /// 40 files (16 + 16 + 8), the middle message failed on its upload; the third waits.
    @MainActor func splitSendWithAFailedMiddle(_ store: HomeStore, _ source: MockHomeSource, tag: String) async throws
        -> (files: [LocalAttachment], failed: IdempotencyKey) {
        var files: [LocalAttachment] = []
        for index in 0..<40 {
            files.append(try await store.prepareAttachment(data: Data("\(tag) \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        await source.failNextUpload(hash: files[20].ref.hash, with: .invalid("attachment_upload_failed"), times: 1)
        _ = try? await store.send(conversation: conversation, text: "", attachments: files)
        await waitUntil { store.log.entries.contains { if case .failed = $0.state { true } else { false } } }
        let failed = try #require(store.log.entries.first { if case .failed = $0.state { true } else { false } }?.intent.key)
        return (files, failed)
    }

    func committedGroups(_ files: [LocalAttachment], in source: MockHomeSource) async throws -> [[String]] {
        let hashes = Set(files.map(\.ref.hash))
        return try await source.snapshot(of: conversation, tail: 20).messages.map { message in
            message.parts.compactMap { if case .attachment(let ref) = $0, hashes.contains(ref.hash) { ref.hash } else { nil } }
        }.filter { !$0.isEmpty }
    }

    /// Review finding: an owner's revocation of a split send's message left it in the chain and
    /// the queue, so the rest never went.
    @MainActor @Test func aRevokedMiddleMessageLetsTheRestGo() async throws {
        let (store, source) = try await started()
        let (files, failed) = try await splitSendWithAFailedMiddle(store, source, tag: "revoked")
        store.handle(.intentsRevoked([failed]))
        await waitUntil { store.log.isEmpty }
        #expect(try await committedGroups(files, in: source) == [files[0..<16].map(\.ref.hash), files[32..<40].map(\.ref.hash)])
    }

    /// Review finding: a split send's next message started while offline only waited for a
    /// reconnect flag, not as an offline send, and could wait forever. Discarding the failed
    /// middle one offline: the third goes at the reconnect.
    @MainActor @Test func theNextMessageStartedOfflineGoesAtTheReconnect() async throws {
        let (store, source) = try await started()
        let (files, failed) = try await splitSendWithAFailedMiddle(store, source, tag: "offline")
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        store.discardFailed(failed)
        #expect(store.log.entries.count == 1)
        await source.setOnline(true)
        await waitUntil { store.log.isEmpty }
        #expect(try await committedGroups(files, in: source) == [files[0..<16].map(\.ref.hash), files[32..<40].map(\.ref.hash)])
    }

    /// Review finding: a link card's picture in a later message was uploaded with the first one,
    /// so a later message had nothing to upload again if the owner swept that picture before it
    /// went. Each message now uploads the blobs its own parts name.
    @MainActor @Test func aLaterMessagesLinkPictureGoesWithThatMessage() async throws {
        let (store, source) = try await started()
        var files: [LocalAttachment] = []
        for index in 0..<16 {
            files.append(try await store.prepareAttachment(data: Data("card \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        let picture = try await store.prepareAttachment(data: Data("not really a jpeg".utf8), typeIdentifier: UTType.plainText.identifier)
        let card = LinkPreview(url: "https://example.com", title: "Example",
                               image: AttachmentDerivedImage(hash: picture.ref.hash, mimeType: picture.ref.mimeType,
                                                             byteCount: picture.ref.byteCount))
        let parts: [MessagePart] = files.map { .attachment($0.ref) } + [.linkPreview(card)]
        // Offline, both messages are logged and wait, so their upload jobs can be read.
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        _ = try? await store.send(conversation: conversation, parts: parts, uploads: files + [picture])
        let keys = store.log.entries.map(\.intent.key)
        try #require(keys.count == 2)
        let first = Set(store.uploads[keys[0]]?.attachments.map(\.ref.hash) ?? [])
        let second = Set(store.uploads[keys[1]]?.attachments.map(\.ref.hash) ?? [])
        #expect(first == Set(files.map(\.ref.hash)))
        #expect(second == [picture.ref.hash])

        await source.setOnline(true)
        await waitUntil { store.log.isEmpty }
        let sent = try await source.snapshot(of: conversation, tail: 20).messages.filter { message in
            message.parts.contains { if case .linkPreview = $0 { true } else { false } }
        }
        #expect(sent.count == 1)
    }

    @MainActor @Test func sixtyFiveFilesSendAsMessagesWithinThePartLimitInOrder() async throws {
        let (store, source) = try await started()

        var files: [LocalAttachment] = []
        for index in 0..<65 {
            files.append(try await store.prepareAttachment(data: Data("file \(index)".utf8), typeIdentifier: UTType.plainText.identifier))
        }
        try await store.send(conversation: conversation, text: "all of them", attachments: files)
        await waitUntil { store.log.isEmpty }

        let hashes = Set(files.map(\.ref.hash))
        let sent = try await source.snapshot(of: conversation, tail: 40).messages.filter { message in
            message.parts.contains { if case .attachment(let ref) = $0 { hashes.contains(ref.hash) } else { false } }
        }
        #expect(sent.count == 5)
        #expect(sent.allSatisfy { $0.parts.count <= HomeAttachmentPolicy.maxParts })
        let order = sent.flatMap { message in
            message.parts.compactMap { if case .attachment(let ref) = $0 { ref.hash } else { nil } }
        }
        #expect(order == files.map(\.ref.hash))
        let texts = sent.flatMap { message in message.parts.compactMap { if case .text(let text, _) = $0 { text } else { nil } } }
        #expect(texts == ["all of them"])
    }
}
