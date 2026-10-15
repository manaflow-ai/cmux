import AppKit
import Foundation

/// The Channels page's native menu on selected message text (POLISH.md right-click contract), in place
/// of the pages' Copy-only default: WebKit's Copy, then Quote in Reply, then Search the Web and
/// WebKit's Look Up; macOS adds Services last. A right-click with nothing selected never gets here
/// with WebKit's Copy: the page's own menus take messages, rows and the composer, and the menu stays
/// empty elsewhere, as the default left it.
@MainActor
enum HomeChannelsSelectionMenu {
    /// The page command Quote in Reply sends; the page quotes its own selection (quoteSelection.ts).
    nonisolated static let quoteCommand = "quoteSelection"
    static let copyItem = "WKMenuItemIdentifierCopy"
    static let lookUpItem = "WKMenuItemIdentifierLookUp"

    struct Actions {
        var quote: () -> Void
        var search: () -> Void
    }

    /// Replaces WebKit's items in `menu` with the selection menu.
    static func rebuild(_ menu: NSMenu, actions: Actions) {
        let copy = menu.items.first { $0.identifier?.rawValue == copyItem }
        let lookUp = menu.items.first { $0.identifier?.rawValue == lookUpItem }
        menu.removeAllItems()
        guard let copy else { return }
        menu.addItem(copy)
        menu.addItem(HomeChannelsMenuAction.item(Strings.quoteInReply, handler: actions.quote))
        menu.addItem(.separator())
        menu.addItem(HomeChannelsMenuAction.item(Strings.searchTheWeb, handler: actions.search))
        if let lookUp { menu.addItem(lookUp) }
    }

    enum Strings {
        static var quoteInReply: String {
            String(localized: "homeChannels.menu.quoteInReply", defaultValue: "Quote in Reply", table: "Handlers", bundle: .module)
        }

        static var searchTheWeb: String {
            String(localized: "homeChannels.menu.searchTheWeb", defaultValue: "Search the Web", table: "Handlers", bundle: .module)
        }
    }
}

/// A menu item's target that runs a closure (the menu item keeps it alive).
final class HomeChannelsMenuAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    /// An item titled `title` that runs `handler`.
    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = HomeChannelsMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
