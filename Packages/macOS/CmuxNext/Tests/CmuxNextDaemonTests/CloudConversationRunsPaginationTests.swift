import Testing
@testable import CmuxNextDaemon

struct CloudConversationRunsPaginationTests {
    @Test func continuesPastVisibleTranscriptBoundaryForOlderStartedRuns() {
        // A loaded reply can be newer than the run's start. The cursor must
        // keep walking after 150 (the oldest run on page one), even if the
        // transcript window starts at 200.
        let first = CloudConversationClient.nextRunsCursor(
            hasMore: true, startedAt: [250, 150], before: nil)
        #expect(first == 150)
        let second = CloudConversationClient.nextRunsCursor(
            hasMore: true, startedAt: [100, 50], before: first)
        #expect(second == 50)
    }

    @Test func stopsOnMissingOrNonAdvancingCloudCursor() {
        #expect(CloudConversationClient.nextRunsCursor(hasMore: false, startedAt: [100], before: nil) == nil)
        #expect(CloudConversationClient.nextRunsCursor(hasMore: true, startedAt: [], before: nil) == nil)
        #expect(CloudConversationClient.nextRunsCursor(hasMore: true, startedAt: [100], before: 100) == nil)
    }
}
