import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// design/menus.md, "Menus spend no width or height on nothing": in a menu whose rows carry icons every row has one,
/// so no row starts its text an empty icon slot in (Leo 2026-11-22, the browser More menu's Show in Toolbar: "some
/// bullshit left indent that indents for literally nothing. either get rid of the indent or give it an icon").
@MainActor
struct MenuIconColumnTests {
    private static func registry() -> ActionRegistry {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id, invoke: { _ in }) }
        return registry
    }

    /// The check itself: a menu mixing icon and icon-less rows fails, one with icons on every row or none passes.
    @Test func theCheckFindsAnIconlessRowBesideIconRows() {
        let mixed = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        mixed.addItem(settings)
        mixed.addItem(.separator())
        let bare = NSMenuItem(title: "Show in Toolbar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Downloads", action: nil, keyEquivalent: "")
        bare.submenu = submenu
        mixed.addItem(bare)
        // The submenu has no icons at all: it reserves no column and is not a finding.
        #expect(MenuIconColumn.rowsWithoutIcon(in: mixed) == ["Show in Toolbar"])

        let plain = NSMenu()
        plain.addItem(withTitle: "Media Controls", action: nil, keyEquivalent: "")
        plain.addItem(withTitle: "Zoom Level", action: nil, keyEquivalent: "")
        #expect(MenuIconColumn.rowsWithoutIcon(in: plain).isEmpty)
    }

    /// The browser toolbar's More (⋮) menu, as `BrowserToolbarHandlers.overflowMenu` builds it (Show in Toolbar at the
    /// end of Tools), on both engines.
    @Test(arguments: [false, true])
    func browserMoreMenuGivesEveryRowAnIcon(chromium: Bool) {
        let registry = Self.registry()
        let buttons = BrowserToolbarButtonsView()
        let entries: [ContextMenuEntry] = [
            .action("browser.extensions.menu"), .action("toggleBrowserDesignMode"), .action("toggleBrowserDeveloperTools"),
            .action("browser.profile.choose"), .choices("browserTheme"), .action("browser.media.show"),
        ]
        let show = buttons.showInToolbarItem(enabled: true) { _ in }
        let more = registry.makeBrowserMoreMenu(tabKey: "t1", buttons: entries, chromium: chromium, toolsFooter: [show]) { buttons.zoomRow($0) }
        #expect(show.menu != nil, "Show in Toolbar is in the menu")
        #expect(show.image != nil)
        #expect(MenuIconColumn.rowsWithoutIcon(in: more).isEmpty, "rows with an empty icon slot")
    }

    /// Every catalog right-click menu: a row of one is drawn with its action's symbol, so an action placed in a
    /// menu beside rows with icons needs a symbol of its own.
    @Test(arguments: ActionMenuContext.allCases)
    func catalogContextMenusGiveEveryRowAnIcon(context: ActionMenuContext) {
        let menu = Self.registry().makeContextMenu(for: context, customize: false)
        #expect(MenuIconColumn.rowsWithoutIcon(in: menu).isEmpty, "\(context.rawValue): rows with an empty icon slot")
    }
}
