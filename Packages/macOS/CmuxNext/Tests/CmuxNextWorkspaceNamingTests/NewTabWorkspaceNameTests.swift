@testable import CmuxNextWorkspaceNaming
import Testing

/// Lucas 2026-11-14: a workspace named after a browser tab on the New Tab page reads "New Tab", as the tab does, not
/// its address's host ("newtab" from `chrome://newtab/`).
struct NewTabWorkspaceNameTests {
    private func browser(_ url: String, title: String? = nil) -> NewWorkspaceName.Tab {
        NewWorkspaceName.Tab(kind: .browser, userName: nil, title: title, pageTitle: nil, url: url, cwd: nil)
    }

    @Test(arguments: ["chrome://newtab/", "chrome://newtab", "about:blank"])
    func theNewTabPageIsNewTab(url: String) {
        #expect(NewWorkspaceName.forTab(browser(url, title: url)) == "New Tab")
    }

    @Test func aPageKeepsItsTitleElseItsHost() {
        #expect(NewWorkspaceName.forTab(browser("https://www.example.com/a", title: "Example Domain")) == "Example Domain")
        #expect(NewWorkspaceName.forTab(browser("https://www.example.com/a")) == "example.com")
    }

    /// Just after a navigation away from the New Tab page the saved address still names it for up to 500 ms; the live
    /// page's title wins (Codex review).
    @Test func aLivePageTitleWinsOverAStaleNewTabAddress() {
        let tab = NewWorkspaceName.Tab(kind: .browser, userName: nil, title: nil, pageTitle: "Example Domain",
                                       url: "chrome://newtab/", cwd: nil)
        #expect(NewWorkspaceName.forTab(tab) == "Example Domain")
    }
}
