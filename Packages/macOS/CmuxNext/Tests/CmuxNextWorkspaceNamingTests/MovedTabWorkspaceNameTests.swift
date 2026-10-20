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

    @Test func whatTheTabShowsNamesIt() {
        // `nameInput` gives a Home, page or app tab the strip's title in place of the record's.
        #expect(NewWorkspaceName.forTab(Self.tab(title: "Chief")) == "Chief")
        #expect(NewWorkspaceName.forTab(Self.tab(title: "Settings")) == "Settings")
    }

    @Test func aUserNameStillWins() {
        #expect(NewWorkspaceName.forTab(Self.tab(title: "about:blank", userName: "Planning")) == "Planning")
    }

    @Test func theLastTabOfAnUnnamedWorkspaceNamesNothingFromAPlaceholder() {
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-4", workspaceTitle: nil, tab: Self.tab(title: "about:blank")) == nil)
        #expect(NewWorkspaceName.forLastTab(workspaceName: "Research", workspaceTitle: nil, tab: Self.tab(title: "about:blank")) == "Research")
    }
}
