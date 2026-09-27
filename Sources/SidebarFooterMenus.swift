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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
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
        let item = SidebarRowClosureMenuItem(title: title, handler: handler)
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
    private var whatsNewCenter: WhatsNewCenter { .shared }

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
                .overlay(alignment: .topTrailing) {
                    // Quiet What's New: a static dot, no motion, cleared once opened.
                    if whatsNewCenter.hasUnseenHighlights {
                        SidebarWhatsNewDot()
                            .offset(x: -3, y: 3)
                    }
                }
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
        let menu = NSMenu(title: helpTitle)
        menu.autoenablesItems = false

        let whatsNew = menu.addSidebarFooterItem(
            String(localized: "sidebar.help.whatsNew", defaultValue: "What's New"),
            identifier: "SidebarHelpMenuOptionWhatsNew"
        ) {
            WhatsNewCenter.shared.presentOnDemand(source: "sidebarHelpMenu")
        }
        if whatsNewCenter.hasUnseenHighlights {
            whatsNew.badge = NSMenuItemBadge(string: String(
                localized: "sidebar.help.whatsNew.badge",
                defaultValue: "New"
            ))
        }
        menu.addSidebarFooterItem(
            String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
            identifier: "SidebarHelpMenuOptionWelcome"
        ) {
            AppDelegate.shared?.openWelcomeWorkspace()
        }
        menu.addSidebarFooterItem(
            String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
            identifier: "SidebarHelpMenuOptionKeyboardShortcuts"
        ) {
            // Presented after the menu's tracking loop has fully unwound so
            // the popover's first click is not eaten by the closing menu.
            DispatchQueue.main.async {
                isShortcutsPopoverPresented = true
            }
        }
        addLink(to: menu, String(localized: "about.docs", defaultValue: "Docs"), url: Self.docsURL, identifier: "SidebarHelpMenuOptionDocs")
        addLink(to: menu, String(localized: "sidebar.help.changelog", defaultValue: "Changelog"), url: Self.changelogURL, identifier: "SidebarHelpMenuOptionChangelog")

        menu.addSidebarFooterSeparator()
        menu.addSidebarFooterItem(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            identifier: "SidebarHelpMenuOptionSettings",
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .openSettings)
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
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .sendFeedback),
            handler: onSendFeedback
        )
        addLink(to: menu, String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"), url: Self.githubIssuesURL, identifier: "SidebarHelpMenuOptionGitHubIssues")
        addLink(to: menu, String(localized: "sidebar.help.discord", defaultValue: "Discord"), url: Self.discordURL, identifier: "SidebarHelpMenuOptionDiscord")
        addLink(to: menu, String(localized: "about.github", defaultValue: "GitHub"), url: Self.githubURL, identifier: "SidebarHelpMenuOptionGitHub")

        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
            menu.addSidebarFooterSeparator()
            menu.addSidebarFooterItem(
                String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
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

/// The quiet What's New indicator: a small accent dot with no animation.
struct SidebarWhatsNewDot: View {
    var body: some View {
        Circle()
            .fill(cmuxAccentColor())
            .frame(width: 6, height: 6)
            .accessibilityLabel(String(localized: "sidebar.help.whatsNew.unseen", defaultValue: "New highlights"))
    }
}
