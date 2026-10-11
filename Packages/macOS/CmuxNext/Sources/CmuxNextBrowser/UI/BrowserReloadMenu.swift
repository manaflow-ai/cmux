import AppKit

/// The Reload button's right-click and long-press menu (cx-2lm4): Reload
/// Page, and Hard Reload Page for a WebKit tab (the engine that reloads from
/// origin, as `browserHardReload` does). Each item keeps its target alive
/// (menu item targets are weak).
@MainActor
final class BrowserReloadMenu: NSObject {
    private let tab: any BrowserTab

    private init(tab: any BrowserTab) {
        self.tab = tab
    }

    static func make(for tab: any BrowserTab) -> NSMenu {
        let target = BrowserReloadMenu(tab: tab)
        let menu = NSMenu()
        var items = [(Strings.menuReload, #selector(reload))]
        if tab is WebKitTab { items.append((Strings.menuHardReload, #selector(hardReload))) }
        for (title, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            (item.target, item.representedObject) = (target, target)
        }
        return menu
    }

    @objc private func reload() { tab.reload() }
    @objc private func hardReload() { (tab as? WebKitTab)?.webView.reloadFromOrigin() }
}
