#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The composer's attachment thumbnail (`AttachmentThumb`) decoded the whole photo with
/// `UIImage(data:)` in `body`, on the main thread, on every render: each keystroke in the
/// composer with a photo attached. It now decodes once, off the main thread, to the 56 pt
/// square at 3x, through the cache sent images use, and `body` only reads the result.
@MainActor @Suite(.serialized) struct ComposerAttachmentThumbTests {
    /// A camera-sized photo (12 MP) attached in the composer: decoded once to a 168 px short
    /// side, and every later read (a keystroke's render) is a cache hit, not a decode.
    @Test func aPhotoIsDecodedOnceToTheThumbSize() async throws {
        let data = try SentAttachmentThumbnailsTests.png(width: 4000, height: 3000, hue: 0.6)
        let attachment = AgentAttachment(id: "composer-thumb-\(UUID().uuidString)", kind: .image, name: "photo.png", data: data)
        let cache = SentAttachmentThumbnails.shared
        #expect(AttachmentThumb.side == 168)

        // Before: what `body` did per render, on the main thread.
        let full = ContinuousClock().measure { _ = UIImage(data: data)?.cgImage?.dataProvider?.data }

        let image = try #require(await cache.decode(attachment, data: data, side: AttachmentThumb.side))
        #expect(min(image.size.width * image.scale, image.size.height * image.scale) <= 168 + 1)

        // After: what `body` does per render.
        var hits = 0
        let reads = ContinuousClock().measure {
            for _ in 0 ..< 100 where cache.image(attachment, data: data, side: AttachmentThumb.side) != nil { hits += 1 }
        }
        #expect(hits == 100)
        #expect(cache.decodes(attachmentID: attachment.id) == 1, "decoded once, not per render")
        print("composer-thumb: full decode per render \(full), 100 cached reads \(reads)")
        cache.evict(attachmentID: attachment.id)
    }

    /// Bytes that do not decode settle (the neutral placeholder) and are not decoded again.
    @Test func bytesThatDoNotDecodeSettle() async {
        let attachment = AgentAttachment(id: "composer-thumb-\(UUID().uuidString)", kind: .image, name: "bad.png", data: Data([1, 2, 3]))
        let cache = SentAttachmentThumbnails.shared
        let first = await cache.decode(attachment, data: attachment.data!, side: AttachmentThumb.side)
        let second = await cache.decode(attachment, data: attachment.data!, side: AttachmentThumb.side)
        #expect(first == nil && second == nil)
        #expect(cache.decodes(attachmentID: attachment.id) == 1)
    }
}
#endif
