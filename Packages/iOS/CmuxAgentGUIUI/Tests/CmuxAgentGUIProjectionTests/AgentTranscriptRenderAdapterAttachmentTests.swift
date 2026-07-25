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
                height: 900,
                aspectRatio: 16.0 / 9.0
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
        #expect(attachment.aspectRatio == 16.0 / 9.0)
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

    @Test("ratio-only image metadata survives projection")
    func ratioOnlyImageMetadataSurvivesProjection() throws {
        let attachment = try Self.projectedAttachment(AttachmentPayload(
            kind: "image",
            summary: "Generated preview",
            displayName: "preview",
            hostPath: "/tmp/generated-preview",
            mimeType: "image/png",
            aspectRatio: 9.0 / 16.0
        ))

        #expect(attachment.media == .image)
        #expect(attachment.pixelWidth == nil)
        #expect(attachment.pixelHeight == nil)
        #expect(attachment.aspectRatio == 9.0 / 16.0)
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

    @Test("markdown image references split into inline agent image rows")
    func markdownImageReferencesSplitIntoInlineAgentImageRows() throws {
        let journalID = JournalID(rawValue: "markdown-image")
        let row = TranscriptRow(
            rowID: .entry(journalID: journalID, seq: EntrySeq(rawValue: 12)),
            rowKind: .proseAgent(
                text: "Here is the preview.\n\n![Agent GUI preview](/tmp/cmux-agent-gui-preview.png)\n\nDone.",
                grouping: .single
            )
        )

        let rendered = AgentTranscriptRenderAdapter().rows(from: [row])
        #expect(rendered.count == 3)

        guard case .message(let first) = rendered[0].content,
              case .prose(let firstProse) = first.message.kind,
              case .message(let image) = rendered[1].content,
              case .attachment(let attachment) = image.message.kind,
              case .message(let last) = rendered[2].content,
              case .prose(let lastProse) = last.message.kind else {
            Issue.record("Expected prose, image attachment, prose render rows")
            return
        }

        #expect(first.message.role == .agent)
        #expect(firstProse.text == "Here is the preview.")
        #expect(image.message.role == .agent)
        #expect(attachment.media == .image)
        #expect(attachment.displayName == "Agent GUI preview")
        #expect(attachment.hostPath == "/tmp/cmux-agent-gui-preview.png")
        #expect(attachment.mimeType == "image/png")
        #expect(last.message.role == .agent)
        #expect(lastProse.text == "Done.")
    }

    @Test("markdown image title dimensions survive projection")
    func markdownImageTitleDimensionsSurviveProjection() throws {
        let attachment = try Self.projectedMarkdownImageAttachment(
            "![Agent GUI preview](/tmp/cmux-agent-gui-preview.png \"640x360\")"
        )

        #expect(attachment.media == .image)
        #expect(attachment.pixelWidth == 640)
        #expect(attachment.pixelHeight == 360)
    }

    @Test("markdown image filename dimensions survive projection")
    func markdownImageFilenameDimensionsSurviveProjection() throws {
        let attachment = try Self.projectedMarkdownImageAttachment(
            "![Agent GUI preview](/tmp/cmux-agent-gui-preview-480x270.png)"
        )

        #expect(attachment.media == .image)
        #expect(attachment.pixelWidth == 480)
        #expect(attachment.pixelHeight == 270)
    }

    @Test("markdown image query dimensions survive projection without polluting host path")
    func markdownImageQueryDimensionsSurviveProjectionWithoutPollutingHostPath() throws {
        let attachment = try Self.projectedMarkdownImageAttachment(
            "![Agent GUI preview](/tmp/cmux-agent-gui-preview.png?width=1024&height=768)"
        )

        #expect(attachment.media == .image)
        #expect(attachment.hostPath == "/tmp/cmux-agent-gui-preview.png")
        #expect(attachment.pixelWidth == 1024)
        #expect(attachment.pixelHeight == 768)
    }

    @Test("attachment author role controls rendered message role")
    func attachmentAuthorRoleControlsRenderedMessageRole() throws {
        let row = TranscriptRow(
            rowID: .entry(journalID: JournalID(rawValue: "agent-attachment"), seq: EntrySeq(rawValue: 1)),
            rowKind: .attachment(AttachmentPayload(
                kind: "image",
                summary: "Preview",
                hostPath: "/tmp/preview.png",
                mimeType: "image/png",
                authorRole: "agent"
            ))
        )

        let rendered = try #require(AgentTranscriptRenderAdapter().rows(from: [row]).first)
        guard case .message(let snapshot) = rendered.content,
              case .attachment = snapshot.message.kind else {
            Issue.record("Expected an attachment message")
            return
        }
        #expect(snapshot.message.role == .agent)
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

    private static func projectedMarkdownImageAttachment(_ markdown: String) throws -> ChatAttachment {
        let row = TranscriptRow(
            rowID: .entry(journalID: JournalID(rawValue: "markdown-image-metadata"), seq: EntrySeq(rawValue: 1)),
            rowKind: .proseAgent(text: markdown, grouping: .single)
        )
        let rendered = try #require(AgentTranscriptRenderAdapter().rows(from: [row]).first)
        guard case .message(let snapshot) = rendered.content,
              case .attachment(let attachment) = snapshot.message.kind else {
            Issue.record("Expected the markdown image row to render as a chat attachment")
            throw AgentTranscriptRenderAdapterAttachmentTestError.expectedAttachment
        }
        return attachment
    }
}

private enum AgentTranscriptRenderAdapterAttachmentTestError: Error {
    case expectedAttachment
}
