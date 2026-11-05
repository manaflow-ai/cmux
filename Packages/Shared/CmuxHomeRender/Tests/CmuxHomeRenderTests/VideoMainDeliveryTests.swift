import AVFoundation
import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeRender

/// AVPlayerItem posts its end and failure notifications on its own threads;
/// VideoPlayback observes them on the main queue, so its handler runs on the
/// main actor (`// main-proof:`), never on the posting thread.
@MainActor @Suite struct VideoMainDeliveryTests {
    final class FileSource: HomeVideoSource {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("video-main-delivery.mov")
        func originalURL(for ref: AttachmentRef) async throws -> URL { url }
    }

    @Test func anEndPostedOffMainIsHandledOnMain() async throws {
        let playback = VideoPlayback()
        let source = FileSource()
        let key = "row-1"
        var changedOnMain: [Bool] = []
        playback.onChange = { _ in changedOnMain.append(Thread.isMainThread) }
        playback.toggle(key, ref: AttachmentFixtures.video, media: source)
        for _ in 0..<200 where playback.state(key) != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(playback.state(key) == .playing)
        let item = try #require(playback.layer(key)?.player?.currentItem)
        let postedOffMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let offMain = !Thread.isMainThread
                NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
                done.resume(returning: offMain)
            }
        }
        #expect(postedOffMain, "the notification was posted off main")
        for _ in 0..<200 where playback.state(key) != .paused { try await Task.sleep(for: .milliseconds(5)) }
        #expect(playback.state(key) == .paused, "the end returned the video to the start, paused")
        #expect(changedOnMain.allSatisfy { $0 }, "every change ran on main")
    }
}
