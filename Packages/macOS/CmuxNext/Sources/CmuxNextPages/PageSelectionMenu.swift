public import AppKit

/// A page's native menu on selected text (POLISH.md right-click contract), in place of the pages'
/// Copy-only default (``PageWebView/contextMenuEditor``): WebKit's Copy, then Quote in Reply, then
/// Search the Web and WebKit's Look Up; macOS adds Services last. With nothing selected WebKit
/// offers no Copy, and the menu stays empty, as the default left it. The Channels page uses it.
@MainActor
public struct PageSelectionMenu {
    /// The page command Quote in Reply sends; the page quotes its own selection (the Channels
    /// page's quoteSelection.ts).
    public nonisolated static let quoteCommand = "quoteSelection"
    static let copyItem = "WKMenuItemIdentifierCopy"
    static let lookUpItem = "WKMenuItemIdentifierLookUp"

    public var quote: () -> Void
    public var search: () -> Void

    public init(quote: @escaping () -> Void, search: @escaping () -> Void) {
        self.quote = quote
        self.search = search
    }

    /// Replaces WebKit's items in `menu` with the selection menu.
    public func rebuild(_ menu: NSMenu) {
        let copy = menu.items.first { $0.identifier?.rawValue == Self.copyItem }
        let lookUp = menu.items.first { $0.identifier?.rawValue == Self.lookUpItem }
        menu.removeAllItems()
        guard let copy else { return }
        menu.addItem(copy)
        menu.addItem(PageMenuAction.item(Strings.quoteInReply, handler: quote))
        menu.addItem(.separator())
        menu.addItem(PageMenuAction.item(Strings.searchTheWeb, handler: search))
        if let lookUp { menu.addItem(lookUp) }
    }

    enum Strings {
        static var quoteInReply: String {
            String(localized: "pages.selectionMenu.quoteInReply", defaultValue: "Quote in Reply", bundle: .module)
        }

        static var searchTheWeb: String {
            String(localized: "pages.selectionMenu.searchTheWeb", defaultValue: "Search the Web", bundle: .module)
        }
    }
}

/// A menu item's target that runs a closure (the menu item keeps it alive).
final class PageMenuAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    /// An item titled `title` that runs `handler`.
    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = PageMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
