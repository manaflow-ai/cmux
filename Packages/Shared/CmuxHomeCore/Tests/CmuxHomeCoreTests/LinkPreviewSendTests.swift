import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxHomeCore

/// The sender's side of `link_preview` parts (iMessage: the sender makes the
/// preview): the part the owner accepts, the preview picture as its own
/// attachment record (JPEG, at most 512 KB), and a send of explicit parts
/// that uploads that picture with the message.
@MainActor
@Suite struct LinkPreviewSendTests {
    let conversation = ConversationID("conv_austin")

    func started() async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory())
        store.start()
        for _ in 0..<5_000 where !(store.isOnline && !store.rows.isEmpty) { await Task.yield() }
        await store.open(conversation)
        for _ in 0..<5_000 where store.transcript(for: conversation).isEmpty { await Task.yield() }
        return (store, source)
    }

    /// A PNG file like the one LinkPreviews writes (`file:` URL).
    func pngFile(width: Int, height: Int, alpha: Bool) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("og.png")
        try makeImage(type: .png, width: width, height: height, alpha: alpha).write(to: url)
        return url
    }

    @Test func sendablePartCleansLabelsAndRefusesWhatTheOwnerRefuses() {
        let image = AttachmentDerivedImage(hash: String(repeating: "c", count: 64), mimeType: "image/jpeg", byteCount: 1000)
        let link = LinkPreview.sendable(url: "https://github.com/manaflow-ai/cmux", title: "  manaflow-ai/cmux:\u{7}\nterminal ",
                                        site: "github.com", image: image)
        #expect(link == LinkPreview(url: "https://github.com/manaflow-ai/cmux", title: "manaflow-ai/cmux:  terminal",
                                    site: "github.com", image: image))
        let long = LinkPreview.sendable(url: "https://example.com", title: String(repeating: "é", count: 400), site: "", image: nil)
        #expect(long?.title?.unicodeScalars.count == 300)
        #expect(long?.site == nil, "an empty site is left out")
        #expect(LinkPreview.sendable(url: "https://user@example.com/", title: nil, site: nil, image: nil) == nil, "user info")
        #expect(LinkPreview.sendable(url: "ftp://example.com/", title: nil, site: nil, image: nil) == nil)
        #expect(LinkPreview.sendable(url: "https://example.com/" + String(repeating: "a", count: 2048), title: nil, site: nil,
                                     image: nil) == nil)
        let png = AttachmentDerivedImage(hash: String(repeating: "c", count: 64), mimeType: "image/png", byteCount: 1000)
        #expect(LinkPreview.sendable(url: "http://example.com", title: "t", site: nil, image: png)?.image == nil,
                "a picture the owner refuses is dropped, the part stays")
    }

    @Test func previewPictureIsAJPEGRecordUnderTheCap() async throws {
        let (store, _) = try await started()
        let big = try await store.prepareLinkPreviewImage(fileURL: try pngFile(width: 2400, height: 1260, alpha: false))
        #expect(big.ref.mimeType == "image/jpeg")
        #expect(big.ref.byteCount <= HomeAttachmentPolicy.previewMaxBytes)
        #expect(max(big.ref.width ?? 0, big.ref.height ?? 0) <= HomeAttachmentPolicy.previewMaxPixel)
        #expect(big.ref.preview == nil && big.ref.poster == nil)
        #expect(try Data(contentsOf: big.fileURL).count == big.ref.byteCount)
        #expect(sha256Hex(try Data(contentsOf: big.fileURL)) == big.ref.hash)

        let clear = try await store.prepareLinkPreviewImage(fileURL: try pngFile(width: 300, height: 200, alpha: true))
        let source = try #require(CGImageSourceCreateWithURL(clear.fileURL as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, "a transparent picture is flattened")
    }

    @Test func explicitPartsUploadThePreviewPictureWithTheMessage() async throws {
        let (store, source) = try await started()
        let picture = try await store.prepareLinkPreviewImage(fileURL: try pngFile(width: 1200, height: 630, alpha: false))
        let image = AttachmentDerivedImage(hash: picture.ref.hash, mimeType: picture.ref.mimeType, byteCount: picture.ref.byteCount)
        let parts: [MessagePart] = [
            .linkPreview(LinkPreview(url: "https://github.com/manaflow-ai/cmux", title: "manaflow-ai/cmux", site: "github.com",
                                     image: image)),
            .text("is this the right repo?"),
        ]
        let key = IdempotencyKey("link-send-1")
        try await store.send(conversation: conversation, parts: parts, uploads: [picture], key: key)
        for _ in 0..<5_000 where store.transcript(for: conversation).last?.delivery != .committed { await Task.yield() }
        let row = try #require(store.transcript(for: conversation).last)
        #expect(row.id == key && row.delivery == .committed)
        #expect(row.parts == parts)
        #expect(row.localAttachments[picture.ref.hash] == picture.files, "my own copy shows the card's picture")
        #expect(await source.uploadCalls == [picture.ref.hash])
        let page = try await source.snapshot(of: conversation, tail: 1)
        #expect(page.messages.last?.parts == parts)
    }

    @Test func aPreviewNamingAnImageNobodyUploadedIsRefused() async throws {
        let (store, _) = try await started()
        let missing = AttachmentDerivedImage(hash: String(repeating: "e", count: 64), mimeType: "image/jpeg", byteCount: 10)
        let parts: [MessagePart] = [.linkPreview(LinkPreview(url: "https://example.com", title: "x", image: missing))]
        await #expect(throws: HomeRejection.invalid("unknown_attachment")) {
            try await store.send(conversation: conversation, parts: parts, uploads: [], key: IdempotencyKey("link-send-2"))
        }
    }
}
