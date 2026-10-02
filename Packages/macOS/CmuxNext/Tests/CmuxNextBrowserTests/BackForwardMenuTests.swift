import AppKit
import Testing
@testable import CmuxNextBrowser

/// Back/forward entry menus (plans/cmux-next/history.md 4.1).
@MainActor
struct BackForwardMenuTests {
    static func entry(_ name: String) -> BrowserNavigationEntry {
        BrowserNavigationEntry(url: URL(string: "https://\(name).example/"), title: name.uppercased())
    }

    @Test func listsBackAndForwardEntriesNearestFirst() {
        let list = BrowserNavigationList(entries: ["a", "b", "c", "d"].map(Self.entry), current: 2)
        #expect(list.back.map(\.offset) == [-1, -2])
        #expect(list.back.map(\.entry.title) == ["B", "A"])
        #expect(list.forward.map(\.offset) == [1])
        #expect(list.forward.map(\.entry.title) == ["D"])
        #expect(BrowserNavigationList(entries: [], current: 0).back.isEmpty)
    }

    @Test func buttonsMenuListsEntriesAndJumpsInOneNavigation() throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        #expect(chrome.backForwardMenu(forward: false) == nil, "no list, no menu")
        tab.navigation = BrowserNavigationList(entries: ["a", "b", "c", "d"].map(Self.entry), current: 2)
        let back = try #require(chrome.backButton.menuProvider?())
        #expect(back.items.map(\.title) == ["B", "A"])
        let forward = try #require(chrome.forwardButton.menuProvider?())
        #expect(forward.items.map(\.title) == ["D"])
        chrome.goToBackForwardEntry(back.items[1])
        #expect(tab.commands.last == .goToEntry(-2))
    }
}
