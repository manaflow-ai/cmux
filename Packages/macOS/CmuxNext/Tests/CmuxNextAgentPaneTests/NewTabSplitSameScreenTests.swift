@testable import CmuxNextAgentPane
import Testing

/// A split's New Tab page (NewTabPage.split) is the Cmd-T context of its source pane plus an Open Tabs list. The
/// spare it adopts was prepared with that Cmd-T context (NewTabSparePool.prepareParked): the two draw one screen,
/// so the page takes the list in the adopt's render instead of remounting (webviews newtab/adoption.ts
/// `sameNewTabScreen`). A remount showed the spare's old screen until the new one painted, after the split.
@MainActor @Suite
struct NewTabSplitSameScreenTests {
    static let prepared = AgentPaneNewTab(kind: .agent, cwd: "/project", home: "/home")

    @Test func aSplitsOpenTabsListDrawsTheCmdTScreen() {
        var split = Self.prepared
        split.openTabs = [AgentPaneOmnibar.Tab(id: "tab", kind: .browser, title: "Tab", detail: "https://example.com")]
        split.inputToken = "split-token"
        #expect(Self.prepared.drawsSameScreen(as: split))
        #expect(split.drawsSameScreen(as: Self.prepared))
    }

    @Test func anotherFolderOrADraftStillRemounts() {
        var folder = Self.prepared
        folder.cwd = "/other"
        #expect(!Self.prepared.drawsSameScreen(as: folder))
        var draft = Self.prepared
        draft.draft = "left over" // the field reads its draft at mount
        #expect(!Self.prepared.drawsSameScreen(as: draft))
    }
}
