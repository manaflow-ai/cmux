import AppKit

/// Link clicks and the link context menu of a WebKit tab, as in Chrome and
/// Safari: Cmd-click and middle click open a background tab, Shift-Cmd-click
/// a foreground tab, Shift-click a new window, Option-click downloads. The
/// menu's "Open Link in New Tab" opens a background tab and "Open Link in
/// New Window" a window; both run WebKit's own item, which creates the page
/// with its opener, after recording where that page goes.
extension WebKitTab {
    typealias LinkClick = WebKitLinkClick

    static func linkClick(flags: NSEvent.ModifierFlags, button: Int) -> LinkClick { WebKitLinkClick(flags: flags, button: button) }

    /// The disposition the link menu picked, once.
    func takeContextMenuDisposition() -> BrowserNewTabDisposition? {
        defer { contextMenuDisposition = nil }
        return contextMenuDisposition
    }

    /// Retitles WebKit's "Open Link in New Window" to "Open Link in New Tab"
    /// (a background tab) and adds "Open Link in New Window" after it.
    func routeLinkMenuItems(in menu: NSMenu) {
        // A pick from an earlier menu that created no page expires here.
        contextMenuDisposition = nil
        guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.openLinkItem }) else { return }
        let item = menu.items[index]
        guard let original = item.action, !(item.target is LinkMenuRoute) else { return }
        let target = item.target
        item.title = Strings.openLinkInNewTab
        let tabRoute = LinkMenuRoute(tab: self, disposition: .backgroundTab, target: target, action: original)
        item.target = tabRoute
        item.action = #selector(LinkMenuRoute.run(_:))
        item.representedObject = tabRoute
        let window = NSMenuItem(title: Strings.openLinkInNewWindow, action: #selector(LinkMenuRoute.run(_:)), keyEquivalent: "")
        let windowRoute = LinkMenuRoute(tab: self, disposition: .newWindow, target: target, action: original)
        window.target = windowRoute
        window.representedObject = windowRoute
        menu.insertItem(window, at: index + 1)
    }

    static let openLinkItem = "WKMenuItemIdentifierOpenLinkInNewWindow"
}

/// Runs WebKit's original link menu action after recording where its page
/// goes. The menu item keeps the route alive (`representedObject`).
final class LinkMenuRoute: NSObject {
    private weak var tab: WebKitTab?
    private let disposition: BrowserNewTabDisposition
    private weak var target: AnyObject?
    private let action: Selector

    init(tab: WebKitTab, disposition: BrowserNewTabDisposition, target: AnyObject?, action: Selector) {
        self.tab = tab
        self.disposition = disposition
        self.target = target
        self.action = action
    }

    @objc func run(_ sender: Any?) {
        tab?.contextMenuDisposition = disposition
        NSApplication.shared.sendAction(action, to: target, from: sender)
    }
}

/// What a link click with modifiers does in a WebKit tab.
enum WebKitLinkClick: Equatable {
    case navigate
    case open(BrowserNewTabDisposition)
    case download

    /// Pure: the modifiers of a link click (`button` 2 is the middle button).
    init(flags: NSEvent.ModifierFlags, button: Int) {
        let flags = flags.intersection([.command, .shift, .option])
        if flags.contains(.command) || button == 2 {
            self = .open(flags.contains(.shift) ? .foregroundTab : .backgroundTab)
        } else if flags == .shift {
            self = .open(.newWindow)
        } else if flags == .option {
            self = .download
        } else {
            self = .navigate
        }
    }
}
