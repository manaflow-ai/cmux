import AppKit
import SwiftUI

/// The native menu behind the sidebar footer's one menu button.
///
/// The button stays a plain `Button` in `SidebarFooterIconButtonStyle`, so it
/// keeps the footer's hover treatment and AppKit-rendered symbols (a SwiftUI
/// `Menu` label cannot host either; see `VaultSessionViewMenuPresenter`).
/// Pressing it pops a real `NSMenu`, which brings row highlight, arrow-key and
/// type-select navigation, press-drag-release selection, right-aligned
/// shortcut glyphs, VoiceOver menu semantics, and exclusivity with every other
/// menu and popover without any footer-specific bookkeeping.
@MainActor
final class SidebarFooterMenuAnchor {
    fileprivate weak var view: NSView?
    /// Keeps the last menu, and so its closure-backed items, alive after
    /// `popUp` returns. AppKit can deliver the chosen item's action after
    /// tracking ends, and an item's `target` is weak: with only a local
    /// reference the item is already gone and the click does nothing.
    private var presentedMenu: NSMenu?

    /// Pops `menu` just above the button, left-aligned with it: the footer sits
    /// at the bottom edge of the window, so a menu hanging below would be
    /// pushed back up by AppKit and cover the button.
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let gap: CGFloat = 4
        // A menu at least as wide as the control that opened it, so the
        // account menu lines up with the chip.
        menu.minimumWidth = max(menu.minimumWidth, view.bounds.width)
        let menuHeight = menu.size.height
        let y = view.isFlipped ? -(menuHeight + gap) : view.bounds.height + gap + menuHeight
        presentedMenu = menu
        if let menu = menu as? SidebarFooterMenu {
            menu.selectedHandler = nil
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
            let selectedHandler = menu.selectedHandler
            menu.selectedHandler = nil
            selectedHandler?()
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
        }
    }
}

/// A footer menu records the selected action while AppKit is tracking it.
/// `SidebarFooterMenuAnchor` invokes that action after `popUp` returns, once
/// the menu's nested tracking loop has finished.
@MainActor
final class SidebarFooterMenu: NSMenu {
    var selectedHandler: (() -> Void)?
    var actionSink: ((() -> Void) -> Void)?

    init(title: String, actionSink: ((() -> Void) -> Void)? = nil) {
        self.actionSink = actionSink
        super.init(title: title)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func record(_ handler: @escaping () -> Void) {
        if let actionSink {
            actionSink(handler)
        } else {
            selectedHandler = handler
        }
    }
}

/// Geometry-only AppKit view placed behind a footer button. It never takes
/// clicks; it only gives the `NSMenu` a view to pop up from.
struct SidebarFooterMenuAnchorView: NSViewRepresentable {
    let anchor: SidebarFooterMenuAnchor

    func makeNSView(context: Context) -> SidebarFooterMenuAnchorNSView {
        let view = SidebarFooterMenuAnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: SidebarFooterMenuAnchorNSView, context: Context) {
        anchor.view = nsView
    }
}

final class SidebarFooterMenuAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSMenu {
    /// Appends a closure-backed item. `identifier` doubles as the XCUITest
    /// identifier; `symbol` is the SF Symbol drawn at the leading edge;
    /// `shortcut` only draws the configured key equivalent, the app-level
    /// binding still owns the key press.
    @MainActor
    @discardableResult
    func addSidebarFooterItem(
        _ title: String,
        identifier: String,
        symbol: String? = nil,
        shortcut: StoredShortcut? = nil,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        // `popUp` runs inside the SwiftUI button's action. Footer menus record
        // the selected handler and the anchor invokes it after tracking ends,
        // so opening a window or sheet is outside AppKit's nested menu call.
        nonisolated(unsafe) let handler = handler
        let item = SidebarRowClosureMenuItem(title: title) { [weak self] in
            guard let footerMenu = self as? SidebarFooterMenu else {
                handler()
                return
            }
            footerMenu.record(handler)
        }
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let shortcut, let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        addItem(item)
        return item
    }

    /// Adds a separator unless the menu is empty or already ends with one.
    func addSidebarFooterSeparator() {
        guard let last = items.last, !last.isSeparatorItem else { return }
        addItem(.separator())
    }
}

// MARK: - Help

/// The help, app and feedback items of the footer menu, shared by every state
/// of `SidebarFooterMenuButton` (signed in, signed out, account button off).
/// Frequent actions stay at the top level; the reading and community links sit
/// in one Help submenu so the menu stays short.
@MainActor
enum SidebarHelpMenuItems {
    private static let docsURL = URL(string: "https://cmux.com/docs")
    private static let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private static let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private static let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private static let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")

    /// Settings, Keyboard Shortcuts, What's New.
    static func addApp(to menu: NSMenu, showKeyboardShortcuts: @escaping () -> Void) {
        menu.addSidebarFooterItem(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            identifier: "SidebarHelpMenuOptionSettings",
            symbol: "gearshape",
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .openSettings)
        ) {
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "sidebarFooterMenu.settings")
            } else {
                AppDelegate.presentPreferencesWindow()
            }
        }
        menu.addSidebarFooterItem(
            String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
            identifier: "SidebarHelpMenuOptionKeyboardShortcuts",
            symbol: "keyboard",
            handler: showKeyboardShortcuts
        )
        let whatsNew = menu.addSidebarFooterItem(
            String(localized: "sidebar.help.whatsNew", defaultValue: "What's New"),
            identifier: "SidebarHelpMenuOptionWhatsNew",
            symbol: "sparkles"
        ) {
            WhatsNewCenter.shared.presentOnDemand(source: "sidebarFooterMenu")
        }
        if WhatsNewCenter.shared.hasUnseenHighlights {
            whatsNew.badge = NSMenuItemBadge(string: String(
                localized: "sidebar.help.whatsNew.badge",
                defaultValue: "New"
            ))
        }
    }

    /// Send Feedback, then the Help submenu of docs and community links.
    static func addHelp(to menu: NSMenu, onSendFeedback: @escaping () -> Void) {
        menu.addSidebarFooterItem(
            String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
            identifier: "SidebarHelpMenuOptionSendFeedback",
            symbol: "bubble.left",
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .sendFeedback),
            handler: onSendFeedback
        )
        let title = String(localized: "sidebar.help.button", defaultValue: "Help")
        let actionSink = (menu as? SidebarFooterMenu)?.actionSink
        let help = SidebarFooterMenu(title: title, actionSink: actionSink)
        help.autoenablesItems = false
        help.addSidebarFooterItem(
            String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
            identifier: "SidebarHelpMenuOptionWelcome",
            symbol: "hand.wave"
        ) {
            AppDelegate.shared?.openWelcomeWorkspace()
        }
        addLink(to: help, String(localized: "about.docs", defaultValue: "Docs"), url: docsURL, identifier: "SidebarHelpMenuOptionDocs", symbol: "book")
        addLink(to: help, String(localized: "sidebar.help.changelog", defaultValue: "Changelog"), url: changelogURL, identifier: "SidebarHelpMenuOptionChangelog", symbol: "list.bullet.rectangle")
        help.addSidebarFooterSeparator()
        addLink(to: help, String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"), url: githubIssuesURL, identifier: "SidebarHelpMenuOptionGitHubIssues", symbol: "exclamationmark.bubble")
        addLink(to: help, String(localized: "sidebar.help.discord", defaultValue: "Discord"), url: discordURL, identifier: "SidebarHelpMenuOptionDiscord", symbol: "bubble.left.and.bubble.right")
        addLink(to: help, String(localized: "about.github", defaultValue: "GitHub"), url: githubURL, identifier: "SidebarHelpMenuOptionGitHub", symbol: "chevron.left.forwardslash.chevron.right")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("SidebarHelpMenuOptionHelp")
        item.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        item.submenu = help
        menu.addItem(item)
    }

    /// Import Browser Data, Check for Updates.
    static func addMaintenance(to menu: NSMenu, browserDataImportCoordinator: BrowserDataImportCoordinator?) {
        menu.addSidebarFooterItem(
            String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
            identifier: "SidebarHelpMenuOptionImportBrowserData",
            symbol: "square.and.arrow.down"
        ) { [browserDataImportCoordinator] in
            browserDataImportCoordinator?.presentImportDialog()
        }
        menu.addSidebarFooterItem(
            String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            identifier: "SidebarHelpMenuOptionCheckForUpdates",
            symbol: "arrow.triangle.2.circlepath"
        ) {
            AppDelegate.shared?.checkForUpdates(nil)
        }
    }

    private static func addLink(to menu: NSMenu, _ title: String, url: URL?, identifier: String, symbol: String) {
        guard let url else { return }
        let item = menu.addSidebarFooterItem(title, identifier: identifier, symbol: symbol) {
            NSWorkspace.shared.open(url)
        }
        item.toolTip = url.absoluteString
    }
}

/// The quiet What's New indicator: a small accent dot with no animation.
struct SidebarWhatsNewDot: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent

    var body: some View {
        Circle()
            .fill(cmuxAccent.color)
            .frame(width: 6, height: 6)
            // A bare shape is not an accessibility element, so the label needs
            // one to attach to or VoiceOver never mentions the dot.
            .accessibilityElement()
            .accessibilityLabel(String(localized: "sidebar.help.whatsNew.unseen", defaultValue: "New highlights"))
    }
}
