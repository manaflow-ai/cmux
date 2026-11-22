import AppKit
import CmuxNextIcons
import CmuxNextTabs
import Testing
@testable import CmuxNextApp

/// Internal page tabs (Settings, History, Diff, ...) draw their page's cmux
/// icon in the tab strip; a page with no registry icon (a third-party app's
/// pane) keeps its SF Symbol.
@MainActor @Suite struct InternalPageTabIconTests {
    final class Provider: InternalPageProvider {
        let icon: IconName?
        init(icon: IconName?) { self.icon = icon }
        var page: InternalPageID { InternalPageID(rawValue: "icon-test") }
        var title: String { "Test" }
        var symbol: String { "square" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    @Test func aPageWithARegistryIconDrawsIt() {
        #expect(InternalPageTabStore.tabIcon(Provider(icon: .settings)) == .icon(.settings))
        #expect(InternalPageTabStore.tabIcon(Provider(icon: nil)) == .symbol("square"))
        #expect(InternalPageTabStore.tabIcon(nil) == .icon(.placeholder))
    }

    @Test func filePagesNameTheirKind() {
        #expect(FilePageKind.markdown.icon == .fileText)
        #expect(FilePageKind.editor.icon == .code)
    }

    /// cmux pages shown in a browser tab (History, Bookmarks, Agent activity,
    /// a remote view) wear their page's icon, not the globe, and no throbber.
    @Test func cmuxAddressesWearTheirPageIcon() {
        let page = { (url: String) in BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: nil, url: URL(string: url)) }
        #expect(page("cmux://history") == .page(.history))
        #expect(page("cmux://bookmarks/") == .page(.bookmarkManager))
        #expect(page("cmux://agent-activity") == .page(.agentActivity))
        #expect(page("cmux://remote-view?host=a") == .page(.machineRemote))
        #expect(page("https://example.com") == .throbber)
        var item = TabItem(id: TabID("h"), title: "History")
        BrowserTabIconState.page(.history).apply(to: &item)
        #expect(item.icon == .icon(.history))
    }
}
