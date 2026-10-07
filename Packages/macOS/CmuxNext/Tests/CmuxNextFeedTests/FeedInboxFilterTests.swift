@testable import CmuxNextFeed
import Foundation
import Testing

struct FeedInboxFilterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ id: String, title: String, github: Bool = false, read: Bool = false) -> FeedItem {
        FeedItem(id: id, title: title, poster: FeedPoster(kind: github ? .integration : .agent,
            label: github ? "GitHub" : "Agent"), readAt: read ? now : nil, createdAt: now)
    }

    @Test func searchMatchesEveryTermAcrossFieldsAndIgnoresCase() {
        let first = item("first", title: "Réview backend", github: true)
        let second = item("second", title: "Review frontend")
        let filter = FeedInboxFilter(query: "  REVIEW github  ")
        #expect(filter.items(from: [first, second]).map(\.id) == ["first"])
    }

    @Test func githubAndUnreadFiltersComposeWithoutChangingReadState() {
        let unread = item("unread", title: "Check failed", github: true)
        let read = item("read", title: "Mention", github: true, read: true)
        let agent = item("agent", title: "Question")
        let filter = FeedInboxFilter(connection: .github, category: .unread)
        #expect(filter.items(from: [unread, read, agent]).map(\.id) == ["unread"])
        #expect(unread.readAt == nil)
        #expect(read.readAt == now)
    }

    @Test func detailRequiresASelectionThatSurvivesTheFilter() {
        let first = item("first", title: "First")
        let second = item("second", title: "Second")
        let filter = FeedInboxFilter(query: "second")
        let groups = FeedInboxGroups(items: filter.items(from: [first, second]), now: now)
        #expect(filter.selectedItem(nil, groups: groups) == nil)
        #expect(filter.selectedItem("first", groups: groups) == nil)
        #expect(filter.selectedItem("second", groups: groups)?.id == "second")
    }
}
