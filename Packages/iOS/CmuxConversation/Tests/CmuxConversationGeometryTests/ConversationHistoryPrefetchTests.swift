import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Older history is asked for well before the reader reaches it: a page
/// comes over the network in about a second, and a fling outruns 1.5
/// screens of runway (iOS 26.5 simulator, ten hard flicks up on the
/// simulator's default latency: the transcript reached the top of what was
/// loaded 3 times and waited 0.9, 2.5 and 5.2 s there).
@Suite struct ConversationHistoryPrefetchTests {
    @Test func asksForThePageFourScreensBeforeTheTop() {
        #expect(ConversationHistoryPrefetch.decision(distanceFromTop: 0, viewport: 900) == .load)
        #expect(ConversationHistoryPrefetch.decision(distanceFromTop: 3599, viewport: 900) == .load)
        #expect(ConversationHistoryPrefetch.decision(distanceFromTop: 3600, viewport: 900) == .none)
    }

    /// A reader who went back down more than six screens no longer wants it
    /// (a failed request stops retrying); in between nothing changes.
    @Test func stopsWantingItSixScreensDown() {
        #expect(ConversationHistoryPrefetch.decision(distanceFromTop: 5400, viewport: 900) == .none)
        #expect(ConversationHistoryPrefetch.decision(distanceFromTop: 5401, viewport: 900) == .stop)
    }
}
