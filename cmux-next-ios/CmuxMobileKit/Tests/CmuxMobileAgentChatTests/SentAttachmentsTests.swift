import CmuxMobileArtifacts
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Live check 2026-10-23 (real Claude Code chat over the link): a prompt sent with a photo and
/// files came back as acpmux's `user_message`, which names images only, so the sent bubble had no
/// attachments to tap. The store keeps what this phone sent per prompt id.
@MainActor
@Suite struct SentAttachmentsTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    @Test func aSentPromptKeepsItsAttachmentsWhenTheMacRecordsIt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        let photo = AgentAttachment(kind: .image, name: "Photo", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let pdf = AgentAttachment(kind: .file, name: "report.pdf", data: Data("%PDF".utf8))
        store.send(prompt: "what is in these?", attachments: [photo, pdf])
        guard case .prompt(_, _, _, let promptID, _)? = source.sent.last else { Issue.record("no prompt"); return }
        // The Mac's record names the image only (no bytes, no files).
        store.apply(.userMessage(text: "what is in these?", promptId: promptID, turnId: "t1",
                                 attachments: [.recordedImage(id: "abc", name: nil)], at: Date()))
        let turn = try #require(store.turns.first)
        #expect(turn.attachments.map(\.name) == ["Photo", "report.pdf"])
        #expect(turn.attachments.allSatisfy { $0.data != nil })
    }

    @Test func aPromptFromElsewhereShowsItsRecordedImages() throws {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "look", promptId: "p9", turnId: "t9",
                                 attachments: [.recordedImage(id: "abc", name: "shot.png")], at: Date()))
        let image = try #require(store.turns.first?.attachments.first)
        #expect(image.recordedImageID == "abc")
        #expect(image.kind == .image)
        #expect(image.name == "shot.png")
        #expect(AgentAttachment(kind: .image, name: "x").recordedImageID == nil)
    }

    @Test func aRecordedImageLoadsItsBytesWhenPreviewed() async throws {
        let image = AgentAttachment.recordedImage(id: "abc", name: nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let request = FilePreviewRequest(files: [image.localFile], startingAt: image.id) { file in
            file.id == image.id ? png : nil
        }
        guard case .image(let data) = try await request.source.load(request.artifacts[0]) else { Issue.record("image"); return }
        #expect(data == png)
    }

    @Test func keptAttachmentsGoOnceRecordedAndStayBounded() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        let file = AgentAttachment(kind: .file, name: "a.txt", data: Data("a".utf8))
        store.send(prompt: "one", attachments: [file])
        guard case .prompt(_, _, _, let first, _)? = source.sent.last else { Issue.record("no prompt"); return }
        #expect(store.sentAttachmentPromptCount == 1)
        store.apply(.userMessage(text: "one", promptId: first, turnId: "t1", attachments: [], at: Date()))
        #expect(store.sentAttachmentPromptCount == 0)
        #expect(store.turns.first?.attachments.map(\.name) == ["a.txt"])
        for n in 0..<(AgentChatStore.maxSentAttachmentPrompts + 4) {
            store.send(prompt: "p\(n)", attachments: [AgentAttachment(kind: .file, name: "f\(n)", data: Data([1]))])
        }
        #expect(store.sentAttachmentPromptCount == AgentChatStore.maxSentAttachmentPrompts)
    }

    @Test func theSameImageTwiceKeepsTwoIdentities() {
        let one = AgentAttachment.recordedImage(id: "abc", name: nil, index: 0)
        let two = AgentAttachment.recordedImage(id: "abc", name: nil, index: 1)
        #expect(one.id != two.id)
        #expect(one.recordedImageID == "abc")
        #expect(two.recordedImageID == "abc")
    }

    @Test func aMacImageThatCantBeReadSaysToConnect() async {
        let image = AgentAttachment.recordedImage(id: "abc", name: nil)
        let request = FilePreviewRequest(files: [image.localFile], startingAt: image.id) { _ in nil }
        await #expect(throws: ArtifactUnavailable("Connect to your Mac to see Photo.")) { try await request.source.load(request.artifacts[0]) }
    }
}
