import CmuxNextBrowserImport
import CmuxNextOnboarding
import Foundation
import Testing

/// Open Tabs: each source profile's last session opens as its own workspace,
/// named after the source, its web pages in the source's window and tab order
/// on the profile the import put that source's data in.
@Suite struct ImportedTabsWorkspaceTests {
    private static func batch(_ name: String, profile: String, tabs: [ImportedTab]) -> ImportBatch {
        let source = ImportSourceRecord(browser: .chrome, profileDirectory: name, displayName: name, proposedProfileID: profile,
                                        targetProfileID: profile)
        var batch = ImportBatch(source: source, kinds: [.openTabs])
        batch.openTabs = tabs
        return batch
    }

    private static func tab(_ address: String, window: Int = 0, pinned: Bool = false) -> ImportedTab {
        ImportedTab(url: URL(string: address)!, title: nil, window: window, pinned: pinned)
    }

    @Test func eachSourceWithTabsBecomesOneWorkspace() {
        let summary = ImportSummary(batches: [
            Self.batch("Google Chrome · Work", profile: "work", tabs: [Self.tab("https://a.example/", pinned: true), Self.tab("https://b.example/", window: 1)]),
            Self.batch("Firefox", profile: "fox", tabs: [Self.tab("https://c.example/")]),
            Self.batch("Arc", profile: "arc", tabs: []),
        ])
        let workspaces = summary.tabWorkspaces
        #expect(workspaces.map(\.name) == ["Google Chrome · Work", "Firefox"])
        #expect(workspaces.map(\.profileID) == ["work", "fox"])
        #expect(workspaces[0].tabs.map(\.url.absoluteString) == ["https://a.example/", "https://b.example/"])
        #expect(workspaces[0].tabs.map(\.pinned) == [true, false])
    }

    @Test func onlyWebPagesOpen() {
        let summary = ImportSummary(batches: [Self.batch("Chrome", profile: "default", tabs: [
            Self.tab("chrome://newtab/"), Self.tab("about:blank"), Self.tab("http://plain.example/"), Self.tab("file:///Users/me/notes.html"),
            Self.tab("https://secure.example/"),
        ]), Self.batch("Firefox", profile: "fox", tabs: [Self.tab("about:home")])])
        #expect(summary.tabWorkspaces.map(\.name) == ["Chrome"])
        #expect(summary.tabWorkspaces.first?.tabs.map(\.url.absoluteString) == ["http://plain.example/", "https://secure.example/"])
    }

    @Test func openTabsAreOfferedUnchecked() {
        #expect(ImportStepModel.offeredKinds.contains(.openTabs))
        #expect(ImportStepModel.optInKinds.contains(.openTabs))
    }
}
