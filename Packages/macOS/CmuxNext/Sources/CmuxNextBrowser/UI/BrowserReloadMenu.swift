import AppKit
import CmuxNextDesign

/// The Reload button's right-click and long-press menu (cx-2lm4): Reload
/// Page, and Hard Reload Page for a WebKit tab (the engine that reloads from
/// origin, as `browserHardReload` does). Each item keeps its target alive
/// (menu item targets are weak). Rows carry their actions' symbols
/// (`browserReload`, `browserHardReload`) and open as a standard macOS menu
/// in the toolbar's light or dark look (`NSMenu.themeRows(in:)`).
@MainActor
final class BrowserReloadMenu: NSObject {
    private let reloadPage: @MainActor () -> Void
    private let hardReloadPage: (@MainActor () -> Void)?

    private init(reload: @escaping @MainActor () -> Void, hardReload: (@MainActor () -> Void)?) {
        reloadPage = reload
        hardReloadPage = hardReload
    }

    static func make(for tab: any BrowserTab, in scope: ThemeScope) -> NSMenu {
        var hardReload: (@MainActor () -> Void)?
        if let webKit = tab as? WebKitTab { hardReload = { webKit.webView.reloadFromOrigin() } }
        return make(reload: { tab.reload() }, hardReload: hardReload, in: scope)
    }

    /// The menu for any engine: Hard Reload Page only when `hardReload` is given.
    static func make(reload: @escaping @MainActor () -> Void, hardReload: (@MainActor () -> Void)?, in scope: ThemeScope) -> NSMenu {
        let target = BrowserReloadMenu(reload: reload, hardReload: hardReload)
        let menu = NSMenu()
        var items = [(Strings.menuReload, "arrow.clockwise", #selector(reloadAction))]
        if hardReload != nil { items.append((Strings.menuHardReload, "arrow.clockwise.circle", #selector(hardReloadAction))) }
        for (title, symbol, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            (item.target, item.representedObject) = (target, target)
            item.image = NSImage.menuSymbol(symbol)
        }
        return menu.themeRows(in: scope)
    }

    @objc private func reloadAction() { reloadPage() }
    @objc private func hardReloadAction() { hardReloadPage?() }
}
