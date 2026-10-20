import AppKit
import SwiftUI

/// Native menus for the sidebar footer's account and Help buttons.
///
/// Both buttons stay plain `Button`s in `SidebarFooterIconButtonStyle`, so they
/// keep the footer's hover treatment and AppKit-rendered symbols (a SwiftUI
/// `Menu` label cannot host either; see `VaultSessionViewMenuPresenter`).
/// Pressing one pops a real `NSMenu`, which brings row highlight, arrow-key and
/// type-select navigation, press-drag-release selection, right-aligned
/// shortcut glyphs, VoiceOver menu semantics, and exclusivity with every other
/// menu and popover without any footer-specific bookkeeping.
@MainActor
final class SidebarFooterMenuAnchor {
    fileprivate weak var view: NSView?
    private var presentedMenu: NSMenu?

    /// Pops `menu` just above the button, left-aligned with it: the footer sits
    /// at the bottom edge of the window, so a menu hanging below would be
    /// pushed back up by AppKit and cover the button.
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let gap: CGFloat = 4
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

/// Records the selected action while AppKit tracks a footer menu. The anchor
/// invokes it after `popUp` returns, once the nested tracking loop is closed.
@MainActor
final class SidebarFooterMenu: NSMenu {
    var selectedHandler: (() -> Void)?

    override init(title: String) {
        super.init(title: title)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func record(_ handler: @escaping () -> Void) {
        selectedHandler = handler
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
    /// identifier; `shortcut` only draws the configured key equivalent, the
    /// app-level binding still owns the key press.
    @MainActor
    @discardableResult
    func addSidebarFooterItem(
        _ title: String,
        identifier: String,
        shortcut: StoredShortcut? = nil,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        nonisolated(unsafe) let handler = handler
        let item = SidebarRowClosureMenuItem(title: title) { [weak self] in
            guard let footerMenu = self as? SidebarFooterMenu else {
                handler()
                return
            }
            footerMenu.record(handler)
        }
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
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

/// The footer's `?` button. Help is grouped the way Mac Help menus are:
/// learning first, then app actions, then feedback and community, with the
/// Pro upsell last so it never sits between a person and the help they came
/// for.
struct SidebarHelpMenuButton: View {
    private static let docsURL = URL(string: "https://cmux.com/docs")
    private static let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private static let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private static let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private static let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
#if DEBUG
    @AppStorage(SidebarFooterHelpIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterHelpIconDebugSettings.defaultSize
    @AppStorage(SidebarFooterHelpIconDebugSettings.weightKey)
    private var debugIconWeight = SidebarFooterHelpIconDebugSettings.defaultWeight.rawValue
#endif
    @Environment(BrowserDataImportCoordinator.self) private var browserDataImportCoordinator: BrowserDataImportCoordinator?

    let onSendFeedback: () -> Void

    @State private var menuAnchor = SidebarFooterMenuAnchor()
    /// The keyboard shortcut cheat sheet, anchored to this button.
    @State private var isShortcutsPopoverPresented = false

    private var iconSize: CGFloat {
#if DEBUG
        CGFloat(debugIconSize)
#else
        SidebarFooterButtonMetrics.helpIconSize
#endif
    }

    private var iconWeight: Font.Weight {
#if DEBUG
        SidebarFooterHelpIconDebugWeight(rawValue: debugIconWeight)?.fontWeight
            ?? SidebarFooterCircularIconStyle.standard.weight
#else
        SidebarFooterCircularIconStyle.standard.weight
#endif
    }

    var body: some View {
        Button {
            menuAnchor.popUp(makeMenu())
        } label: {
            SidebarFooterHelpIcon(pointSize: iconSize, weight: iconWeight)
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(SidebarFooterMenuAnchorView(anchor: menuAnchor))
        .popover(isPresented: $isShortcutsPopoverPresented, arrowEdge: .top) {
            AllShortcutsPopover()
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private func makeMenu() -> NSMenu {
        let menu = SidebarFooterMenu(title: helpTitle)
        menu.autoenablesItems = false

        menu.addSidebarFooterItem(
            String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
            identifier: "SidebarHelpMenuOptionWelcome"
        ) {
            AppDelegate.shared?.openWelcomeWorkspace()
        }
        let shortcutsPresented = $isShortcutsPopoverPresented
        menu.addSidebarFooterItem(
            String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
            identifier: "SidebarHelpMenuOptionKeyboardShortcuts"
        ) {
            shortcutsPresented.wrappedValue = true
        }
        addLink(to: menu, String(localized: "about.docs", defaultValue: "Docs"), url: Self.docsURL, identifier: "SidebarHelpMenuOptionDocs")
        addLink(to: menu, String(localized: "sidebar.help.changelog", defaultValue: "Changelog"), url: Self.changelogURL, identifier: "SidebarHelpMenuOptionChangelog")

        menu.addSidebarFooterSeparator()
        menu.addSidebarFooterItem(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            identifier: "SidebarHelpMenuOptionSettings",
            shortcut: KeyboardShortcutSettings.shortcut(for: .openSettings)
        ) {
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "sidebarHelpMenu.settings")
            } else {
                AppDelegate.presentPreferencesWindow()
            }
        }
        menu.addSidebarFooterItem(
            String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
            identifier: "SidebarHelpMenuOptionImportBrowserData"
        ) { [browserDataImportCoordinator] in
            browserDataImportCoordinator?.presentImportDialog()
        }
        menu.addSidebarFooterItem(
            String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            identifier: "SidebarHelpMenuOptionCheckForUpdates"
        ) {
            AppDelegate.shared?.checkForUpdates(nil)
        }

        menu.addSidebarFooterSeparator()
        menu.addSidebarFooterItem(
            String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
            identifier: "SidebarHelpMenuOptionSendFeedback",
            shortcut: KeyboardShortcutSettings.shortcut(for: .sendFeedback),
            handler: onSendFeedback
        )
        addLink(to: menu, String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"), url: Self.githubIssuesURL, identifier: "SidebarHelpMenuOptionGitHubIssues")
        addLink(to: menu, String(localized: "sidebar.help.discord", defaultValue: "Discord"), url: Self.discordURL, identifier: "SidebarHelpMenuOptionDiscord")
        addLink(to: menu, String(localized: "about.github", defaultValue: "GitHub"), url: Self.githubURL, identifier: "SidebarHelpMenuOptionGitHub")

        if let offer = ProUpgradePresenter.currentUpgradeOffer {
            menu.addSidebarFooterSeparator()
            menu.addSidebarFooterItem(
                ProUpgradePresenter.upgradeMenuTitle(for: offer),
                identifier: "SidebarHelpMenuOptionUpgrade"
            ) {
                ProUpgradePresenter.present(source: .sidebarHelpMenu)
            }
        }
        return menu
    }

    private func addLink(to menu: NSMenu, _ title: String, url: URL?, identifier: String) {
        guard let url else { return }
        let item = menu.addSidebarFooterItem(title, identifier: identifier) {
            NSWorkspace.shared.open(url)
        }
        item.toolTip = url.absoluteString
    }
}
