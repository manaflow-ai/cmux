import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import Testing

/// The Channels page's native menu on selected message text (POLISH.md right-click contract): WebKit's
/// Copy, then Quote in Reply, then Search the Web and WebKit's Look Up (macOS adds Services last),
/// instead of Copy alone. With nothing selected WebKit offers no Copy, and the menu stays empty.
@MainActor
struct HomeChannelsSelectionMenuTests {
    /// WebKit's default menu on selected text, by its item identifiers.
    static func webKitMenu(_ ids: [String]) -> NSMenu {
        let menu = NSMenu()
        for id in ids {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        return menu
    }

    @Test func selectedTextGetsCopyQuoteSearchAndLookUp() {
        #expect(PageDescriptor.homeChannels.commands.contains(PageSelectionMenu.quoteCommand))
        var ran: [String] = []
        let menu = Self.webKitMenu(["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierSearchWeb",
                                    "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu"])
        PageSelectionMenu(quote: { ran.append("quote") }, search: { ran.append("search") }).rebuild(menu)

        // WebKit's items by identifier, the page's by title (AppKit names an item's identifier after its action).
        let webKit = { (item: NSMenuItem) in item.identifier?.rawValue.hasPrefix("WKMenuItemIdentifier") == true }
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : webKit($0) ? $0.identifier!.rawValue : $0.title } == [
            "WKMenuItemIdentifierCopy", PageSelectionMenu.Strings.quoteInReply, "-",
            PageSelectionMenu.Strings.searchTheWeb, "WKMenuItemIdentifierLookUp",
        ])
        for title in [PageSelectionMenu.Strings.quoteInReply, PageSelectionMenu.Strings.searchTheWeb] {
            let item = menu.items.first { $0.title == title }
            if let item, let action = item.action { _ = (item.target as? NSObject)?.perform(action, with: item) }
        }
        #expect(ran == ["quote", "search"])
    }

    @Test func nothingSelectedLeavesNoMenu() {
        let menu = Self.webKitMenu(["WKMenuItemIdentifierReload", "WKMenuItemIdentifierInspectElement"])
        PageSelectionMenu(quote: {}, search: {}).rebuild(menu)
        #expect(menu.items.isEmpty)
    }
}
