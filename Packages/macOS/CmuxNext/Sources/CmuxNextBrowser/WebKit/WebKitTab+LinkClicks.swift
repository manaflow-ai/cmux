import AppKit
import WebKit

/// Link clicks and the link context menu of a WebKit tab. Modified clicks
/// follow the engine's `BrowserLinkClickMapping` (Chrome's defaults:
/// Cmd-click and middle click open a background tab, Shift-Cmd-click a
/// foreground tab, Shift-click a new window, Option-click downloads). The
/// menu's "Open Link in New Tab" opens a background tab and "Open Link in
/// New Window" a window; both run WebKit's own item, which creates the page
/// with its opener, after recording where that page goes.
extension WebKitTab {
    typealias LinkClick = WebKitLinkClick

    static func linkClick(flags: NSEvent.ModifierFlags, button: Int, mapping: BrowserLinkClickMapping = .chrome) -> LinkClick {
        WebKitLinkClick(flags: flags, button: button, mapping: mapping)
    }

    /// The disposition the link menu picked, once.
    func takeContextMenuDisposition() -> BrowserNewTabDisposition? {
        defer { contextMenuDisposition = nil }
        return contextMenuDisposition
    }
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

    static let openLinkItem = "WKMenuItemIdentifierOpenLinkInNewWindow"

    /// Retitles WebKit's "Open Link in New Window" to "Open Link in New Tab"
    /// (a background tab) and adds "Open Link in New Window" after it.
    static func install(in menu: NSMenu, tab: WebKitTab) {
        // A pick from an earlier menu that created no page expires here.
        tab.contextMenuDisposition = nil
        guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == openLinkItem }) else { return }
        let item = menu.items[index]
        guard let original = item.action, !(item.target is LinkMenuRoute) else { return }
        let target = item.target
        item.title = Strings.openLinkInNewTab
        let tabRoute = LinkMenuRoute(tab: tab, disposition: .backgroundTab, target: target, action: original)
        item.target = tabRoute
        item.action = #selector(run(_:))
        item.representedObject = tabRoute
        let window = NSMenuItem(title: Strings.openLinkInNewWindow, action: #selector(run(_:)), keyEquivalent: "")
        let windowRoute = LinkMenuRoute(tab: tab, disposition: .newWindow, target: target, action: original)
        window.target = windowRoute
        window.representedObject = windowRoute
        menu.insertItem(window, at: index + 1)
    }
}

/// What a link click with modifiers does in a WebKit tab.
enum WebKitLinkClick: Equatable {
    /// A plain click: the page's own behavior (a link loads here, a
    /// `target=_blank` link opens a selected tab).
    case pageDefault
    /// A modified click mapped to the current tab.
    case navigate
    case open(BrowserNewTabDisposition)
    case download

    /// What a click does in `tab` (`WebKitEngine.linkClicks`).
    @MainActor
    init(_ action: WKNavigationAction, in tab: WebKitTab) {
        self.init(flags: action.modifierFlags, button: action.buttonNumber, mapping: tab.engine?.linkClicks ?? .chrome)
    }

    /// Pure: the modifiers of a link click (`button` 2 is the middle button)
    /// through `mapping`.
    init(flags: NSEvent.ModifierFlags, button: Int, mapping: BrowserLinkClickMapping) {
        let gesture = BrowserLinkGesture(flags: flags, button: button)
        guard gesture != .plain else {
            self = .pageDefault
            return
        }
        let action = mapping.action(for: gesture)
        if let disposition = action.newTabDisposition {
            self = .open(disposition)
        } else {
            self = action == .download ? .download : .navigate
        }
    }

    /// A modified click mapped to the current tab or to a download, on a
    /// link that opens a page window: the opener loads or downloads it, and
    /// no page is created. False for every other click.
    @MainActor
    func runsInOpener(_ request: URLRequest, tab: WebKitTab) -> Bool {
        switch self {
        case .navigate:
            tab.webView.load(request)
        case .download:
            guard let url = request.url, WebKitTab.isWebScheme(url) else { return true }
            tab.webView.startDownload(using: request) { [weak tab] download in tab?.register(download, source: url) }
        case .open, .pageDefault:
            return false
        }
        return true
    }
}
