@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The Feed is its own page behind `experiments.feed` (off by default, ask c-9f58e14079): one "Feed" sidebar
/// item, not in the default layout and hidden while the setting is off, that opens the page on top through
/// `feed.show`.
@MainActor
struct FeedEntryTests {
    @Test func theSidebarItemOpensTheFeedTopPage() {
        #expect(SidebarBuiltIn(rawValue: "feed") == .feed)
        #expect(SidebarBridge.builtInActions[.feed] == "feed.show")
        #expect(TopPageRoute.route(for: .builtIn(.feed)) == .page(.feed))
        #expect(TopPageRoute(rawValue: TopPageRoute.page(.feed).rawValue) == .page(.feed))
        #expect(SidebarLayoutDocument.defaults.firstItem(with: .builtIn(.feed)) == nil)
        #expect(!SidebarBuiltIn.feed.title.isEmpty)
    }

    @Test func theItemHidesWhileTheExperimentIsOff() {
        #expect(SidebarBuiltIn.feed.defaultInfo(showsStore: true).isHidden)
        #expect(SidebarBuiltIn.feed.defaultInfo(showsStore: true, showsForum: true).isHidden)
        #expect(!SidebarBuiltIn.feed.defaultInfo(showsStore: true, showsFeed: true).isHidden)
        #expect(!SidebarBuiltIn.forum.defaultInfo(showsStore: true, showsForum: true, showsFeed: false).isHidden)
    }
}
