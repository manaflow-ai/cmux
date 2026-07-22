#if os(iOS)
import CmuxAgentChat
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing

@testable import CmuxAgentGUIUI

@Suite("Agent transcript attachment rendering")
struct AgentTranscriptRenderAdapterAttachmentTests {
    @Test("image metadata survives replica-to-chat projection")
    func imageMetadataSurvivesProjection() throws {
        let journalID = JournalID(rawValue: "image-metadata")
        let seq = EntrySeq(rawValue: 9)
        let row = TranscriptRow(
            rowID: .entry(journalID: journalID, seq: seq),
            rowKind: .attachment(AttachmentPayload(
                kind: "image",
                summary: "Screenshot",
                attachmentID: "attachment-9",
                displayName: "screen.png",
                hostPath: "/tmp/screen.png",
                mimeType: "image/png",
                byteCount: 456_789,
                width: 1_600,
                height: 900
            ))
        )

        let rendered = try #require(AgentTranscriptRenderAdapter().rows(from: [row]).first)
        guard case .message(let snapshot) = rendered.content,
              case .attachment(let attachment) = snapshot.message.kind else {
            Issue.record("Expected the attachment row to render as a chat attachment")
            return
        }

        #expect(attachment.media == .image)
        #expect(attachment.displayName == "screen.png")
        #expect(attachment.hostPath == "/tmp/screen.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.byteCount == 456_789)
        #expect(attachment.pixelWidth == 1_600)
        #expect(attachment.pixelHeight == 900)
    }
}
#endif
