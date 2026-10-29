import Foundation
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

// Leo, 2026-10-26: "why the FUCK SHOULD THERE BE A FUCKING SIZE CAP ANYWAYS ... I ALREADY SAID WE NEED
// ARBITARRILY LARGE FILES OF ANY TYPE". A send with more files than the owner's parts per message
// (`HomeAttachmentPolicy.maxParts`, cmux-conversation `MAX_PARTS`) was refused as `tooManyParts`, and
// the native composer refused the 16th file. Now the send goes as several messages, in order.

@Suite(.timeLimit(.minutes(3))) struct AttachmentAnyCountSendTests {
    let conversation = ConversationID("conv_austin")

    @MainActor @Test func sixtyFiveFilesSendAsMessagesWithinThePartLimitInOrder() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }

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
