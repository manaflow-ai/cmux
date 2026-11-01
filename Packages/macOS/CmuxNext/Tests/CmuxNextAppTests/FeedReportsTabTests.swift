@testable import CmuxNextFeed
import Foundation
import Testing

/// The reports basket is a tab of the Feed inbox, on by default (Leo-ask ask-b7707cc5b2), next to
/// GitHub and Feed. The Feed's item list keeps no row under it; the header test is
/// `ThemedPlainFieldsTests.theFeedReportsTabHidesTheItemSearch`.
struct FeedReportsTabTests {
    @Test func theReportsTabListsNoFeedItems() {
        let item = FeedItem(id: "fi_1", title: "Finished", body: "done", context: FeedContext(tab: "tab_1"),
                            poster: FeedPoster(kind: .agent, label: "Agent"), createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(FeedInboxFilter(connection: .feed).items(from: [item]).map(\.id) == ["fi_1"])
        #expect(FeedInboxFilter(connection: .reports).items(from: [item]).isEmpty)
    }
}
