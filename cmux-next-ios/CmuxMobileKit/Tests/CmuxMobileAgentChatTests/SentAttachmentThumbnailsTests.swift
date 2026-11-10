#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Review of #27664 at 2a38f796: the sent-image thumbnail cache a tab card's picture waits for
/// (`SentAttachmentThumbnails.ready`) must settle. Bytes that do not decode count as ready (the
/// picture draws the placeholder, as before), and a burst of images past the cache's bound
/// stays under it in memory without decoding the same images again and again.
@MainActor @Suite(.serialized) struct SentAttachmentThumbnailsTests {
    static func png(width: Int, height: Int, hue: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.pngData())
    }

    static func turn(_ n: Int, data: Data) -> AgentTurn {
        var turn = AgentTurn(id: "t\(n)", prompt: "p\(n)", promptAt: Date(timeIntervalSince1970: 0))
        turn.attachments = [AgentAttachment(id: "a\(n)", kind: .image, name: "\(n).png", data: data)]
        turn.status = .completed
        return turn
    }

    /// Calls `ready` once per ~20 ms for `rounds` rounds (as card bodies do while they wait).
    func settle(_ cache: SentAttachmentThumbnails, _ turns: [AgentTurn], rounds: Int) async -> Bool {
        var ready = false
        for _ in 0 ..< rounds {
            ready = cache.ready(turns)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ready
    }

    /// Bytes `UIImage(data:)` cannot read stored nothing and bumped nothing: the card waited
    /// for its thumbnail forever (a live preview for good) and every body started the decode
    /// again. A failed decode counts as ready, and is not started again.
    @Test func bytesThatDoNotDecodeCountAsReady() async {
        let cache = SentAttachmentThumbnails()
        let turns = [Self.turn(0, data: Data([0x01, 0x02, 0x03]))]
        let ready = await settle(cache, turns, rounds: 30)
        #expect(ready, "an image that cannot be decoded does not hold the card")
        #expect(cache.decodes == 1, "decoded once, not once per read: \(cache.decodes)")
    }

    /// A burst of images past the cache's bound: what it keeps stays under the bound, every
    /// card's thumbnails count as ready, and once they have landed nothing is decoded again
    /// (an eviction must not start a decode that evicts another, and so on).
    @Test func aBurstPastTheBoundSettles() async throws {
        let bound = 4 << 20
        let cache = SentAttachmentThumbnails(byteLimit: bound)
        let turns = try (0 ..< 12).map { Self.turn($0, data: try Self.png(width: 800, height: 600, hue: CGFloat($0) / 12)) }
        let ready = await settle(cache, turns, rounds: 60)
        #expect(ready, "every thumbnail of the burst counts as ready")
        let decodes = cache.decodes, revision = cache.revision
        let still = await settle(cache, turns, rounds: 20)
        #expect(still)
        #expect(cache.decodes == decodes && cache.revision == revision,
                "settled: decodes \(decodes) -> \(cache.decodes), revision \(revision) -> \(cache.revision)")
        #expect(cache.residentBytes <= bound, "kept \(cache.residentBytes) bytes, bound \(bound)")
    }

    /// Review of the follow-up (P2): a waiting picture's hold took a thumbnail only when the
    /// picture asked again, so with many cards waiting one decoded for it could be let go by the
    /// bound before its turn, and be decoded again (the eviction ping-pong, at queue scale). A
    /// thumbnail goes into the holds waiting for it as it lands: two that do not fit the bound
    /// together are each decoded once, and the picture can be drawn.
    @Test func aWaitingPictureHoldsWhatIsDecodedForIt() async throws {
        // Each thumbnail is 600 x 1200 px (2.9 MB): one fits the bound, two do not.
        let cache = SentAttachmentThumbnails(byteLimit: 4 << 20)
        let turns = try (0 ..< 2).map { Self.turn($0, data: try Self.png(width: 600, height: 1200, hue: CGFloat($0) / 2)) }
        let hold = SentAttachmentHold()
        try #require(!cache.resident(turns, holding: hold), "nothing decoded yet")
        for _ in 0 ..< 200 where cache.decodes == 2 && hold.images.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let resident = cache.resident(turns, holding: hold)
        #expect(resident, "both thumbnails are held for the picture")
        #expect(cache.decodes == 2, "each decoded once: \(cache.decodes) decodes")
        #expect(cache.residentBytes <= 4 << 20, "the cache stays under its bound: \(cache.residentBytes)")
    }

    /// Review of #27664 (follow-up P2): only a thumbnail's short side was scaled, so a very tall
    /// screenshot decoded to 600 x 9000 (about 22 MB). A card whose last turns carried two of them
    /// passed the 32 MB bound: each landing evicted the other, `resident` never held for both, and
    /// the rasterizer re-queued and decoded them again on every frame. A thumbnail keeps no more
    /// of the image than its bubble can show, the card's thumbnails are in memory together, and
    /// once they are nothing is decoded again.
    @Test func twoVeryTallImagesSettleUnderTheBound() async throws {
        let bound = 32 << 20
        let cache = SentAttachmentThumbnails(byteLimit: bound)
        let turns = try (0 ..< 2).map { Self.turn($0, data: try Self.png(width: 600, height: 9000, hue: CGFloat($0) / 2)) }
        let ready = await settle(cache, turns, rounds: 100)
        try #require(ready, "both thumbnails count as ready")
        // As the rasterizer asks before it draws the card, once per frame.
        var resident = false
        for _ in 0 ..< 60 {
            resident = cache.resident(turns)
            try? await Task.sleep(for: .milliseconds(20))
        }
        let decodes = cache.decodes
        for _ in 0 ..< 20 {
            resident = cache.resident(turns)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(resident, "both thumbnails are in memory together, to draw the card")
        #expect(cache.decodes == decodes, "settled: decodes \(decodes) -> \(cache.decodes)")
        #expect(cache.residentBytes <= bound / 4, "kept \(cache.residentBytes) bytes for two thumbnails")
        let side = SentAttachmentThumbnails.side(SentAttachmentThumbnails.size(images: 1))
        for turn in turns {
            let attachment = try #require(turn.attachments.first)
            let data = try #require(attachment.data)
            let image = try #require(cache.image(attachment, data: data, side: side)?.cgImage,
                                     "\(attachment.id) is drawn from memory")
            #expect(CGFloat(min(image.width, image.height)) >= side, "sharp at its bubble's size: \(image.width)x\(image.height)")
            #expect(CGFloat(max(image.width, image.height)) <= side * 2, "no longer than its bubble shows: \(image.width)x\(image.height)")
        }
    }
}
#endif
