@testable import CmuxNextWorkspaceNaming
import Testing

/// A New Tab page dragged out of a workspace onto the sidebar named its new workspace
/// "about:blank" (Leo 2026-10-19): `TabMoves.nameInput` read the conversation tab's record, whose
/// title is the `about:blank` placeholder, as a terminal's live title, and the daemon kept that
/// name as the user's. A placeholder title never names a workspace; what the tab shows does.
struct MovedTabWorkspaceNameTests {
    private static func tab(title: String?, userName: String? = nil, cwd: String? = nil) -> NewWorkspaceName.Tab {
        NewWorkspaceName.Tab(kind: .terminal, userName: userName, title: title, pageTitle: nil, url: nil, cwd: cwd)
    }

    @Test(arguments: ["about:blank", "About:Blank", "chrome://newtab/", "chrome://newtab", "  about:blank  "])
    func aPlaceholderTitleNamesNothing(_ title: String) {
        #expect(NewWorkspaceName.forTab(Self.tab(title: title)) == nil)
    }

    @Test func aPlaceholderTitleFallsBackToTheFolder() {
        #expect(NewWorkspaceName.forTab(Self.tab(title: "about:blank", cwd: "/Users/me/src/cmux")) == "cmux")
    }

    private static func page(_ title: String?, userName: String? = nil) -> NewWorkspaceName.Tab {
        NewWorkspaceName.Tab(kind: .page, userName: userName, title: title, pageTitle: nil, url: nil, cwd: "/Users/me/src/cmux")
    }

    /// `TabMoves.nameInput` reads a conversation, page or app tab as `.page`, with the name it shows of its own.
    @Test func aPageTabIsNamedByWhatItShows() {
        #expect(NewWorkspaceName.forTab(Self.page("Chief")) == "Chief")
        #expect(NewWorkspaceName.forTab(Self.page("Settings")) == "Settings")
        #expect(NewWorkspaceName.forTab(Self.page("README.md", userName: "Docs")) == "Docs")
    }

    /// The What's New tab dragged out of an unnamed workspace to the sidebar named its workspace
    /// "workspace-42" (Leo 2026-10-20): its record's title is the placeholder, read as a terminal's
    /// with no folder. As a page it takes the title it shows, even as its workspace's last tab.
    @Test func theWhatsNewTabNamesItsWorkspace() {
        #expect(NewWorkspaceName.forTab(Self.page("What’s New")) == "What’s New")
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-42", workspaceTitle: nil, tab: Self.page("What’s New")) == "What’s New")
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-42", workspaceTitle: nil, tab: Self.page("Settings")) == "Settings")
    }

    /// A New Tab page, a chat, an untitled Home tab or an app with no page names nothing, and never its folder.
    @Test(arguments: [nil, "", "about:blank", "chrome://newtab/"] as [String?])
    func aPageTabWithNoNameOfItsOwnNamesNothing(_ title: String?) {
        #expect(NewWorkspaceName.forTab(Self.page(title)) == nil)
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-9", workspaceTitle: nil, tab: Self.page(title)) == nil)
    }

    @Test func aUserNameStillWins() {
        #expect(NewWorkspaceName.forTab(Self.tab(title: "about:blank", userName: "Planning")) == "Planning")
    }

    @Test func theLastTabOfAnUnnamedWorkspaceNamesNothingFromAPlaceholder() {
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-4", workspaceTitle: nil, tab: Self.tab(title: "about:blank")) == nil)
        #expect(NewWorkspaceName.forLastTab(workspaceName: "Research", workspaceTitle: nil, tab: Self.tab(title: "about:blank")) == "Research")
    }

    @Test func aModernUserHomeMarkerSurvivesMovingItsLastTab() {
        #expect(NewWorkspaceName.forLastTab(workspaceName: "~", workspaceTitle: nil, tabName: "api",
                                             workspaceNameSource: .user, workspaceNameRevision: 0,
                                             allowsLegacyDefaults: false) == "~")
    }
}
