import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Recently Closed names a closed page tab (a diff, Settings) by its page, not by the page tab's
/// `about:blank` placeholder (cx-h7y9). The daemon's `closed.list` record names the page.
@MainActor
struct ClosedPageTabTitleTests {
    private final class DiffPage: InternalPageProvider {
        var page: InternalPageID { InternalPageID(rawValue: "diff") }
        var title: String { "Changes" }
        var symbol: String { "plusminus" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// One closed tab as `closed.list` lists it.
    private static func closed(_ tab: String) throws -> ClosedItem {
        let json = """
        {"id":"closed_1","kind":"tab","name":null,"workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":1,
         "screens":[{"name":null,"tabs":[\(tab)]}],"window":null,"member_count":1,"members":[]}
        """
        return try JSONDecoder().decode(ClosedItem.self, from: Data(json.utf8))
    }

    @Test func aClosedPageTabIsNamedByItsPage() throws {
        let pages = InternalPageTabStore()
        pages.register(DiffPage())
        let item = try Self.closed("""
            {"kind":"browser","name":null,"cwd":null,"url":"about:blank","browser_profile_id":null,"pinned":false,"page":"diff"}
            """)
        let text = HistoryService.daemonClosedText(item, pages: pages)
        #expect(text.title == "Changes")
        #expect(text.detail == nil)
    }

    @Test(arguments: [nil, "Pinned chat"] as [String?])
    func aClosedAgentUsesItsStoredNameOrStableAgentTitle(_ name: String?) throws {
        var item = try Self.closed("""
            {"kind":"browser","name":null,"cwd":null,"url":"about:blank","browser_profile_id":null,"pinned":false,
             "agent_session":{"session":"same-session","harness":"codex"}}
            """)
        var tab = try #require(item.tabs.first)
        tab.name = name
        item.screens = [.init(tabs: [tab])]

        let text = HistoryService.daemonClosedText(item, pages: InternalPageTabStore())

        #expect(text.title == (name ?? AgentPaneModel.tabTitle))
        #expect(text.detail == nil)
    }

    /// A browser tab, and a record from a daemon that names no page, keep their address.
    @Test func otherTabsKeepTheirAddress() throws {
        let pages = InternalPageTabStore()
        pages.register(DiffPage())
        let item = try Self.closed("""
            {"kind":"browser","name":null,"cwd":null,"url":"https://cmux.com/","browser_profile_id":null,"pinned":false}
            """)
        let text = HistoryService.daemonClosedText(item, pages: pages)
        #expect(text.title == "https://cmux.com/")
        #expect(text.detail == "https://cmux.com/")
    }
}
