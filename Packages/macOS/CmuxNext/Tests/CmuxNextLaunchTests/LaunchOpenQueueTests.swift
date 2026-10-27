import CmuxNextLaunch
import Foundation
import Testing

/// URLs and Handoff activities macOS hands over before the services exist are kept and handed over
/// once, in arrival order, when the launch builds them (p08-startup 025).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchOpenQueueTests {
    @Test func keptOpensAreHandedOverOnceInArrivalOrder() throws {
        let queue = LaunchOpenQueue()
        let link = try #require(URL(string: "https://example.com/a"))
        let page = try #require(URL(string: "https://example.com/handoff"))
        queue.hold(.url(link))
        queue.hold(.activity(type: NSUserActivityTypeBrowsingWeb, webpageURL: page))
        var delivered: [LaunchOpenQueue.Item] = []
        queue.release { delivered.append($0) }
        #expect(delivered == [.url(link), .activity(type: NSUserActivityTypeBrowsingWeb, webpageURL: page)],
                "a URL or a Handoff activity from before the services was lost or reordered")
        #expect(queue.items.isEmpty)
        queue.release { _ in Issue.record("an open was handed over twice") }
    }
}
