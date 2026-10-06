import Foundation
import Testing
@testable import CmuxHomeCore

/// A link preview part (`link_preview` on the wire): the sender's fetched
/// preview, whose image is an ordinary attachment blob the store fetches
/// and keeps like an attachment picture.
@Suite struct LinkPreviewPartTests {
    private let image = AttachmentDerivedImage(hash: String(repeating: "d", count: 64), mimeType: "image/jpeg", byteCount: 900)

    @Test func aLinkPreviewKeepsItsFieldsThroughCodableAndShowsItsTitle() throws {
        let link = LinkPreview(url: "https://example.com/post", title: "A post", site: "example.com", image: image)
        let part = MessagePart.linkPreview(link)
        #expect(try JSONDecoder().decode(MessagePart.self, from: JSONEncoder().encode(part)) == part)
        #expect(part.plainText == "A post")
        #expect(MessagePart.linkPreview(LinkPreview(url: "https://example.com")).plainText == "https://example.com")
    }

    @Test func aLinkPreviewImageIsABlobOfItsRow() {
        let attachment = AttachmentRef(hash: String(repeating: "a", count: 64), name: "a.png", mimeType: "image/png", byteCount: 10,
                                       preview: AttachmentDerivedImage(hash: String(repeating: "b", count: 64), mimeType: "image/jpeg", byteCount: 5))
        let parts: [MessagePart] = [.text("look"), .attachment(attachment),
                                    .linkPreview(LinkPreview(url: "https://example.com", image: image)),
                                    .linkPreview(LinkPreview(url: "https://example.org"))]
        #expect(parts.flatMap(\.blobHashes) == [attachment.hash, String(repeating: "b", count: 64), image.hash])
        let row = TranscriptItem(key: IdempotencyKey("k"), seq: 1, author: ParticipantID("user_a"), parts: parts,
                                 createdAt: Date(timeIntervalSince1970: 0), delivery: .committed)
        #expect(row.attachmentHashes == [attachment.hash, image.hash])
    }
}
