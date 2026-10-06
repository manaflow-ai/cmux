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
}
