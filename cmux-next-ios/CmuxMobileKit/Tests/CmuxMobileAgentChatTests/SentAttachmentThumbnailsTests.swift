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
}
#endif
