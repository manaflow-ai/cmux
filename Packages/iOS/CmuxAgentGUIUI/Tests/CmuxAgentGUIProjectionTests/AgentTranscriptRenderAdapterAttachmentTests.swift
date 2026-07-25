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

    @Test("image extension without MIME type still renders inline")
    func imageExtensionWithoutMIMETypeStillRendersInline() throws {
        let attachment = try Self.projectedAttachment(AttachmentPayload(
            kind: "file",
            summary: "Screenshot",
            displayName: "screen.PNG",
            hostPath: "/tmp/screen.PNG",
            mimeType: nil
        ))

        #expect(attachment.media == .image)
        #expect(attachment.displayName == "screen.PNG")
        #expect(attachment.hostPath == "/tmp/screen.PNG")
    }

    @Test("image dimensions without MIME type still render inline")
    func imageDimensionsWithoutMIMETypeStillRenderInline() throws {
        let attachment = try Self.projectedAttachment(AttachmentPayload(
            kind: "artifact",
            summary: "Generated preview",
            displayName: nil,
            hostPath: "/tmp/generated-preview",
            mimeType: nil,
            width: 512,
            height: 768
        ))

        #expect(attachment.media == .image)
        #expect(attachment.pixelWidth == 512)
        #expect(attachment.pixelHeight == 768)
    }

    @Test("SVG artifact paths render as inline image previews")
    func svgArtifactPathsRenderAsInlineImagePreviews() throws {
        let attachment = try Self.projectedAttachment(AttachmentPayload(
            kind: "file",
            summary: "Vector preview",
            displayName: "diagram.svg",
            hostPath: "/tmp/diagram.svg",
            mimeType: "image/svg+xml",
            byteCount: 1_024,
            width: 480,
            height: 270
        ))

        #expect(attachment.media == .image)
        #expect(attachment.displayName == "diagram.svg")
        #expect(attachment.hostPath == "/tmp/diagram.svg")
        #expect(attachment.mimeType == "image/svg+xml")
        #expect(attachment.byteCount == 1_024)
        #expect(attachment.pixelWidth == 480)
        #expect(attachment.pixelHeight == 270)
    }

    private static func projectedAttachment(_ payload: AttachmentPayload) throws -> ChatAttachment {
        let row = TranscriptRow(
            rowID: .entry(journalID: JournalID(rawValue: "image-fallback"), seq: EntrySeq(rawValue: 1)),
            rowKind: .attachment(payload)
        )
        let rendered = try #require(AgentTranscriptRenderAdapter().rows(from: [row]).first)
        guard case .message(let snapshot) = rendered.content,
              case .attachment(let attachment) = snapshot.message.kind else {
            Issue.record("Expected the attachment row to render as a chat attachment")
            throw AgentTranscriptRenderAdapterAttachmentTestError.expectedAttachment
        }
        return attachment
    }
}

private enum AgentTranscriptRenderAdapterAttachmentTestError: Error {
    case expectedAttachment
}
#endif
