import AppKit
@testable import CmuxNextPages
import Testing

/// A viewer page's menu on selected text: WebKit's Copy, then Comment… and Quote in Chat
/// (viewer-comments-DESIGN.md). With no selection WebKit offers no Copy and no row shows.
@MainActor
struct ViewerSelectionMenuTests {
    static func webKitMenu(_ ids: [String]) -> NSMenu {
        let menu = NSMenu()
        for id in ids {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        return menu
    }

    @Test func selectedTextGetsCopyThenTheRows() {
        var ran: [String] = []
        let menu = Self.webKitMenu(["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierShareMenu"])
        ViewerSelectionMenu(rows: [
            .init(title: ViewerSelectionMenu.Titles.comment) { ran.append("comment") },
            .init(title: ViewerSelectionMenu.Titles.quoteInChat) { ran.append("quote") },
        ]).apply(to: menu)

        let shown = menu.items.map { $0.isSeparatorItem ? "-" : $0.identifier?.rawValue.hasPrefix("WK") == true ? $0.identifier!.rawValue : $0.title }
        #expect(shown == ["WKMenuItemIdentifierCopy", "-", ViewerSelectionMenu.Titles.comment, ViewerSelectionMenu.Titles.quoteInChat])
        for item in menu.items where !item.isSeparatorItem && item.identifier?.rawValue.hasPrefix("WK") != true {
            if let action = item.action { _ = (item.target as? NSObject)?.perform(action, with: item) }
        }
        #expect(ran == ["comment", "quote"])
    }

    @Test func thePagesOwnItemsComeAfterTheRowsWithOrWithoutASelection() {
        let extra: @MainActor (NSMenu) -> Void = { $0.addItem(NSMenuItem(title: "Reset Column Widths", action: nil, keyEquivalent: "")) }
        let selected = Self.webKitMenu(["WKMenuItemIdentifierCopy"])
        ViewerSelectionMenu(rows: [.init(title: "Comment…") {}], then: extra).apply(to: selected)
        #expect(selected.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["WKMenuItemIdentifierCopy", "-", "Comment…", "Reset Column Widths"])
        let unselected = Self.webKitMenu(["WKMenuItemIdentifierReload"])
        ViewerSelectionMenu(rows: [.init(title: "Comment…") {}], then: extra).apply(to: unselected)
        #expect(unselected.items.map(\.title) == ["Reset Column Widths"])
    }

    @Test func noSelectionShowsNoRows() {
        let menu = Self.webKitMenu(["WKMenuItemIdentifierReload", "WKMenuItemIdentifierInspectElement"])
        ViewerSelectionMenu(rows: [.init(title: "x") {}]).apply(to: menu)
        #expect(menu.items.isEmpty)
    }
}
