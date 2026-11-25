@testable import CmuxMobileFeed
import Testing

/// Leo, 2026-11-24 (item 3): "all the connecting... indicators and the graying out of workspaces,
/// nah let's not do that. let's just keep optimistically connecting and reinforcing the
/// connection". An empty Feed before the Mac has answered draws nothing under its chips: no
/// spinner and no "Connecting to your Mac…"; the events fill in when they arrive.
///
/// Fails on feat-cmux-next before this change: there `FeedEmptyBody` does not exist and the
/// header drew `connectingState` (placeholder `feed.connecting`) while `syncState == .connecting`.
@Suite struct FeedNoConnectingTests {
    @Test func anEmptyFeedBeforeTheMacAnswersDrawsNothing() {
        for filter in FeedFilter.allCases {
            #expect(FeedEmptyBody.resolve(isEmpty: true, sync: .connecting, filter: filter) == nil, "\(filter)")
        }
    }

    @Test func theEmptyStatesWaitForTheMacsAnswer() {
        #expect(FeedEmptyBody.resolve(isEmpty: true, sync: .live, filter: .needsYou) == .caughtUp)
        #expect(FeedEmptyBody.resolve(isEmpty: true, sync: .live, filter: .all) == .noEvents)
        #expect(FeedEmptyBody.resolve(isEmpty: false, sync: .live, filter: .all) == nil, "rows on screen: no empty state")
    }

    /// The account's cached snapshot already said what the Feed holds: a filter with no rows says
    /// so while the Mac reconnects, instead of a blank screen.
    @Test func aKnownFeedSaysEmptyWhileReconnecting() {
        #expect(FeedEmptyBody.resolve(isEmpty: true, sync: .connecting, filter: .needsYou, known: true) == .caughtUp)
        #expect(FeedEmptyBody.resolve(isEmpty: true, sync: .connecting, filter: .all, known: true) == .noEvents)
        #expect(FeedEmptyBody.resolve(isEmpty: false, sync: .connecting, filter: .all, known: true) == nil)
    }
}
