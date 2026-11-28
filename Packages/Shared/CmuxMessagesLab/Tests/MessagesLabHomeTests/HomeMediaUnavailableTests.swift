import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A picture that cannot be had at all (every try failed: the record is gone, this host cannot read it) draws as a
/// file card with its type, name and size, never the empty gray box the user saw beside "3 Replies" (2026-11-16).
@MainActor @Suite struct HomeMediaUnavailableTests {
    @Test func aPictureThatCannotBeHadIsAFileCard() async throws {
        let media = HomeMedia()
        media.retryDelays = [.milliseconds(5), .milliseconds(5)]
        let calls = HomeMediaPreviewTests.Fetcher { _, _ in throw HomeRejection.invalid("attachment_not_loaded") }
        media.fetch = calls.fetch
        var ready: [String] = []
        media.onReady = { ready.append($0) }
        let ref = AttachmentRef(hash: "gone-\(UUID().uuidString)", name: "CleanShot.png", mimeType: "image/png",
                                byteCount: 107_824, width: 2256, height: 454)
        media.request(ref)
        await media.settled()
        #expect(calls.count == 3, "one try and two retries")
        #expect(ready == [ref.hash], "the rows showing it redraw once it is given up")
        #expect(media.asset(ref.hash) == HomeMedia.unavailableAsset)
        let card = HomeMapping.attachment(ref, picture: media.asset(ref.hash), progress: nil)
        #expect(card.kind == "file")
        #expect(card.asset == nil && card.poster == nil)
        #expect(HomeFileCard.isCard(card))
    }

    /// A video that cannot be had is a file card as well (its name and size, not a play button on nothing).
    @Test func aVideoThatCannotBeHadIsAFileCard() {
        let ref = AttachmentRef(hash: "v", name: "clip.mp4", mimeType: "video/mp4", byteCount: 9000)
        #expect(HomeMapping.attachment(ref, picture: HomeMedia.unavailableAsset, progress: nil).kind == "file")
        #expect(HomeMapping.attachment(ref, picture: nil, progress: nil).kind == "video")
    }
}
