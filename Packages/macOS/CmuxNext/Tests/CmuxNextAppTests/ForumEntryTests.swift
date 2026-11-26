@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The Forum page is reachable behind `experiments.forum` (off by default): one "Forum" sidebar
/// item, not in the default layout and hidden while the setting is off, that opens the page on top
/// through `forum.show`.
@MainActor
struct ForumEntryTests {
    @Test func theSidebarItemOpensTheForumTopPage() {
        #expect(SidebarBuiltIn(rawValue: "forum") == .forum)
        #expect(SidebarBridge.builtInActions[.forum] == "forum.show")
        #expect(TopPageRoute.route(for: .builtIn(.forum)) == .page(.forum))
        #expect(TopPageRoute(rawValue: TopPageRoute.page(.forum).rawValue) == .page(.forum))
        #expect(SidebarLayoutDocument.defaults.firstItem(with: .builtIn(.forum)) == nil)
        #expect(!SidebarBuiltIn.forum.title.isEmpty)
    }

    @Test func theItemHidesWhileTheExperimentIsOff() {
        #expect(SidebarBuiltIn.forum.defaultInfo(showsStore: true).isHidden)
        #expect(!SidebarBuiltIn.forum.defaultInfo(showsStore: true, showsForum: true).isHidden)
        #expect(!SidebarBuiltIn.automations.defaultInfo(showsStore: true, showsForum: false).isHidden)
    }
}
