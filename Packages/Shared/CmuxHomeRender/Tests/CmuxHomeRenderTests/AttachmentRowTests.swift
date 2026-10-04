import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Image, video and file attachments in the transcript: bubbles sized from
/// the pixel size before any byte arrives, the file chip, the send morph and
/// inline video playback. Everything runs on a fake loader.
@MainActor
@Suite struct AttachmentRowTests {
    private func rows(_ parts: [MessagePart], author: ParticipantID = Fixtures.chief, width: CGFloat = 628) -> [RowSpec] {
        let c = Fixtures.controller(width: width)
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, author, parts)]), summary: Fixtures.summary(),
                 typing: [], hasOlder: false)
        return c.scene.model.rows.map(\.spec).filter { $0.partRow != nil }
    }

    @Test func mediaBubblesAreSizedFromThePixelSize() throws {
        let photo = try #require(rows([.attachment(AttachmentFixtures.photo)]).first?.partRow)
        #expect(photo.size == CGSize(width: 300, height: 225), "a 1200 x 900 photo is 300 pt wide at its aspect")
        let video = try #require(rows([.attachment(AttachmentFixtures.video)]).first?.partRow)
        #expect(video.size == CGSize(width: 300, height: 169))
        let tall = try #require(rows([.attachment(AttachmentFixtures.tall)]).first?.partRow)
        #expect(tall.size == CGSize(width: 300, height: 360), "a tall image is capped at 360 pt and cropped")
        let small = AttachmentRef(hash: "s", name: "icon.png", mimeType: "image/png", byteCount: 900, width: 120, height: 80)
        let icon = try #require(rows([.attachment(small)]).first?.partRow)
        #expect(icon.size == CGSize(width: 60, height: 40), "a small image keeps its 2x point size")
        let narrow = try #require(rows([.attachment(AttachmentFixtures.photo)], width: 320).first?.partRow)
        #expect(narrow.size.width <= 320 - 40, "a bubble never leaves a narrow viewport")
        if case .media(let media) = photo.content { #expect(!media.isVideo) } else { Issue.record("a photo is a media row") }
        if case .media(let media) = video.content { #expect(media.isVideo) } else { Issue.record("a video is a media row") }
    }

    @Test func bytesArrivingDoNotReflowTheTranscript() async throws {
        let loader = FakeAttachmentLoader()
        await loader.hold()
        let c = Fixtures.controller(height: 900)
        c.attachmentLoader = loader
        var messages = Fixtures.conversation(6)
        messages.append(AttachmentFixtures.message(7, Fixtures.chief, [.attachment(AttachmentFixtures.photo)]))
        messages.append(AttachmentFixtures.message(8, Fixtures.me, [.text("Nice")]))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let key = "part:key_7:0"
        let index = try #require(c.scene.model.index[key])
        let specBefore = c.scene.model.rows[index].spec
        let heightBefore = c.scene.layout.contentHeight
        let commits = c.scene.commitCount
        let row = try #require(c.scene.visible[key])
        #expect(row.mediaImage.contents == nil, "no bytes yet: the bubble shows its placeholder at its final size")
        #expect(row.mediaImage.frame.size.width >= specBefore.partRow?.size.width ?? .infinity)
        await loader.release()
        await c.attachmentsSettled()
        #expect(row.mediaImage.contents != nil, "the image lands in the bubble")
        #expect(c.scene.commitCount == commits, "bytes arriving lay nothing out")
        #expect(c.scene.layout.contentHeight == heightBefore)
        #expect(c.scene.model.rows[index].spec == specBefore)
        #expect(await loader.thumbnailRequests == [AttachmentFixtures.photo.hash])
    }

    @Test func theFileChipShowsNameKindAndSize() throws {
        let file = try #require(rows([.attachment(AttachmentFixtures.pdf)]).first?.partRow)
        guard case .file(let chip) = file.content else { Issue.record("a PDF is a file row"); return }
        #expect(chip.name == "report.pdf")
        #expect(chip.kind == "PDF Document")
        #expect(chip.detail == "PDF Document \u{00B7} 1.2 MB")
        #expect(chip.badge == "PDF")
        #expect(file.size.height == FileChip.height)
        let unsized = try #require(rows([.attachment(AttachmentFixtures.unsizedImage)]).first?.partRow)
        if case .file = unsized.content {} else { Issue.record("an image without a pixel size shows as a file") }

        let c = Fixtures.controller(height: 900)
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.chief, [.attachment(AttachmentFixtures.pdf)])]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        let ax = try #require(c.accessibilityItems().first { $0.id == "part:key_1:0" })
        #expect(ax.label == "report.pdf, PDF Document, 1.2 MB")
        #expect(ax.value == "From Chief")
        let photo = Fixtures.controller(height: 900)
        photo.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.me, [.attachment(AttachmentFixtures.photo)])]),
                     summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(photo.accessibilityItems().first { $0.id == "part:key_1:0" }?.label == "Photo, beach.jpg")
    }

    @Test func aHostedSendOfAnAttachmentMorphsIntoItsBubble() throws {
        let c = Fixtures.controller(width: 628, height: 800)
        c.setHostedField(CGRect(x: 51, y: 759, width: 526, height: 30))
        let messages = Fixtures.conversation(6)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        var emitted: [HomeIntent] = []
        c.onIntent = { emitted.append($0) }
        let field = try #require(c.scene.hostedField)
        let tray = CGRect(x: 60, y: 700, width: 48, height: 36)
        let outgoing = HomeOutgoingAttachment(ref: AttachmentFixtures.photo, origin: tray, preview: nil)
        let intent = try #require(c.sendHosted(text: "Look", attachments: [outgoing], from: field))
        #expect(emitted == [intent])
        guard case .sendMessage(_, let parts) = intent.op else { Issue.record("not a send"); return }
        #expect(parts == [.attachment(AttachmentFixtures.photo), .text("Look")], "attachments first, then the text")
        #expect(c.sendHosted(text: " ", attachments: [], from: field) == nil, "nothing to send")
        c.update(items: Fixtures.items(messages, pending: [PendingIntent(intent: intent)]), summary: Fixtures.summary(),
                 typing: [], hasOlder: false)
        let key = "part:\(intent.key.rawValue):0"
        let morph = try #require(c.scene.morphs[key], "the attachment flies into its bubble")
        #expect(morph.target.size == CGSize(width: 300, height: 225), "it lands at the size laid out from the pixel size")
        #expect(morph.origin == tray, "it starts at the draft thumbnail")
        #expect(c.scene.morphs["part:\(intent.key.rawValue):1"] != nil, "the text part flies too")
        #expect(c.scene.ledger.live(key).contains { $0.hold == 0 }, "the row stays hidden until the morph lands")
    }

    @Test func aVideoShowsItsPosterThenPlaysInline() async throws {
        let loader = FakeAttachmentLoader()
        let c = Fixtures.controller(height: 900)
        c.attachmentLoader = loader
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.chief, [.attachment(AttachmentFixtures.video)])]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        let key = "part:key_1:0"
        let item = IdempotencyKey("key_1")
        #expect(c.videoState(for: item, partIndex: 0) == .poster)
        await c.attachmentsSettled()
        let row = try #require(c.scene.visible[key])
        #expect(row.mediaImage.contents != nil, "the poster frame shows before playback")
        #expect(!row.playBadge.isHidden, "the play badge shows over the poster")
        #expect(await loader.originalRequests.isEmpty, "the video's bytes load only on play")

        let bubble = try #require(c.contentFrame(for: item))
        let hit = try #require(c.hit(at: CGPoint(x: 40, y: bubble.midY - c.scrollGeometry.offset)))
        #expect(hit.attachment == AttachmentFixtures.video)
        #expect(c.toggleVideo(hit))
        #expect(c.videoState(for: item, partIndex: 0) == .loading)
        await c.attachmentsSettled()
        #expect(c.videoState(for: item, partIndex: 0) == .playing)
        #expect(row.hasPlayer, "the player layer sits inside the bubble")
        #expect(row.playBadge.isHidden)
        #expect(await loader.originalRequests == [AttachmentFixtures.video.hash])
        #expect(c.toggleVideo(hit))
        #expect(c.videoState(for: item, partIndex: 0) == .paused)
        #expect(!row.playBadge.isHidden)
        let photo = HomeHit(item: item, partIndex: 0, text: "", isMine: false, bubble: .zero, attachment: AttachmentFixtures.photo)
        #expect(!c.toggleVideo(photo), "a photo does not play")
    }

    @Test func aVideoWithoutAPosterKeepsItsPlaceholderAndNeverFetchesTheVideo() async throws {
        let loader = FakeAttachmentLoader()
        await loader.setNoPoster()
        let c = Fixtures.controller(height: 900)
        c.attachmentLoader = loader
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.chief, [.attachment(AttachmentFixtures.video)])]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.attachmentsSettled()
        let row = try #require(c.scene.visible["part:key_1:0"])
        #expect(row.mediaImage.contents == nil, "no poster: the placeholder stays")
        #expect(!row.playBadge.isHidden, "the video can still be played")
        #expect(await loader.posterRequests == [AttachmentFixtures.video.hash])
        #expect(await loader.originalRequests.isEmpty, "the video's bytes are never fetched for a frame")
        #expect(await loader.thumbnailRequests.isEmpty)
    }

    @Test func uploadProgressDrawsARingWithoutALayoutPass() throws {
        let c = Fixtures.controller(height: 900)
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.me, [.attachment(AttachmentFixtures.photo)]),
                                        AttachmentFixtures.message(2, Fixtures.me, [.attachment(AttachmentFixtures.pdf)])]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        let commits = c.scene.commitCount
        let photo = try #require(c.scene.visible["part:key_1:0"])
        let file = try #require(c.scene.visible["part:key_2:0"])
        #expect(photo.progressRing.isHidden)
        c.setUploadProgress([AttachmentFixtures.photo.hash: 0.4, AttachmentFixtures.pdf.hash: 0.9])
        #expect(!photo.progressRing.isHidden)
        #expect(abs(photo.progressRing.strokeEnd - 0.4) < 0.001)
        #expect(abs(file.progressRing.strokeEnd - 0.9) < 0.001)
        c.setUploadProgress([:])
        #expect(photo.progressRing.isHidden, "an attachment that finished uploading shows no ring")
        #expect(c.scene.commitCount == commits)
    }

    @Test func aRefusedSendGivesItsAttachmentsBack() throws {
        let c = Fixtures.controller(width: 628, height: 800)
        c.setHostedField(CGRect(x: 51, y: 759, width: 526, height: 30))
        var restored: [AttachmentRef] = []
        var text = ""
        c.onRestoreAttachments = { restored = $0 }
        c.onRestoreDraft = { text = $0 }
        let intent = try #require(c.sendHosted(text: "Look", attachments: [HomeOutgoingAttachment(ref: AttachmentFixtures.pdf)],
                                                from: CGRect(x: 51, y: 759, width: 526, height: 30)))
        c.restoreDraft(for: intent.key)
        #expect(text == "Look")
        #expect(restored == [AttachmentFixtures.pdf], "the draft gets its attachments back with its text")
    }

    @Test func inboxPreviewLabelsCountTheirKind() {
        #expect(HomeAttachmentSummary.label(AttachmentPreview(kind: .photo, count: 1)) == "Photo")
        #expect(HomeAttachmentSummary.label(AttachmentPreview(kind: .photo, count: 2)) == "2 photos")
        #expect(HomeAttachmentSummary.label(AttachmentPreview(kind: .video, count: 1)) == "Video")
        #expect(HomeAttachmentSummary.label(AttachmentPreview(kind: .audio, count: 1)) == "Voice message")
        #expect(HomeAttachmentSummary.label(AttachmentPreview(kind: .file, count: 3)) == "3 files")
    }

    @Test func aPreviewFromTheHostShowsAtOnce() throws {
        let c = Fixtures.controller(height: 900)
        let preview = try #require(Canvas.image(size: CGSize(width: 8, height: 6)) { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 6)) })
        c.usePreview(preview, for: AttachmentFixtures.photo)
        c.update(items: Fixtures.items([AttachmentFixtures.message(1, Fixtures.me, [.attachment(AttachmentFixtures.photo)])]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        let row = try #require(c.scene.visible["part:key_1:0"])
        #expect(row.mediaImage.contents != nil, "a draft's own preview needs no fetch")
    }
}
