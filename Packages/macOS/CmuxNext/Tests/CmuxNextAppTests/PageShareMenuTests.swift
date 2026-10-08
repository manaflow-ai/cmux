import AppKit
@testable import CmuxNextApp
import Testing

/// cx-k9go: a web page's right-click menu ends with the system Share… row
/// for the page's address; cmux:// pages and files get none.
@MainActor @Suite struct PageShareMenuTests {
    @Test func aWebPageGetsTheShareRow() throws {
        let items = PageShareMenu.items(for: URL(string: "https://example.com/a"))
        #expect(items.count == 2)
        #expect(items.first?.isSeparatorItem == true)
        let share = try #require(items.last)
        #expect(!share.isSeparatorItem && !share.title.isEmpty)
    }

    @Test func otherAddressesGetNone() {
        #expect(PageShareMenu.items(for: nil).isEmpty)
        #expect(PageShareMenu.items(for: URL(string: "cmux://settings")).isEmpty)
        #expect(PageShareMenu.items(for: URL(fileURLWithPath: "/tmp/a.html")).isEmpty)
    }
}
