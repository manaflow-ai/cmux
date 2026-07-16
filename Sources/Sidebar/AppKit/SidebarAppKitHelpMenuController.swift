import AppKit

/// Lazily builds and presents the native menu anchored to the AppKit sidebar footer.
@MainActor
final class SidebarAppKitHelpMenuController: NSObject {
    enum Action: String, CaseIterable {
        case welcome
        case keyboardShortcuts
        case importBrowserData
        case docs
        case changelog
        case github
        case githubIssues
        case discord
    }

    struct Callbacks {
        let onHelpAction: (Action) -> Void
        let onCheckForUpdates: () -> Void
        let onSendFeedback: () -> Void
    }

    private let callbacks: Callbacks
    private var cachedMenu: NSMenu?

    private(set) var menuBuildCount = 0

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init()
    }

    var isMenuLoaded: Bool { cachedMenu != nil }

    /// The same menu instance is reused after its first access.
    var menu: NSMenu {
        if let cachedMenu {
            return cachedMenu
        }
        let menu = makeMenu()
        cachedMenu = menu
        menuBuildCount += 1
        return menu
    }

    func present(relativeTo anchorView: NSView) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 4),
            in: anchorView
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(
            title: String(localized: "sidebar.help.button", defaultValue: "Help")
        )
        menu.autoenablesItems = false

        menu.addItem(helpItem(
            title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
            action: .welcome,
            accessibilityIdentifier: "SidebarHelpMenuOptionWelcome"
        ))
        menu.addItem(callbackItem(
            title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
            selector: #selector(sendFeedback(_:)),
            accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback"
        ))
        menu.addItem(helpItem(
            title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
            action: .keyboardShortcuts,
            accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts"
        ))
        menu.addItem(helpItem(
            title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
            action: .importBrowserData,
            accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData"
        ))
        menu.addItem(.separator())
        menu.addItem(helpItem(
            title: String(localized: "about.docs", defaultValue: "Docs"),
            action: .docs,
            accessibilityIdentifier: "SidebarHelpMenuOptionDocs"
        ))
        menu.addItem(helpItem(
            title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
            action: .changelog,
            accessibilityIdentifier: "SidebarHelpMenuOptionChangelog"
        ))
        menu.addItem(helpItem(
            title: String(localized: "about.github", defaultValue: "GitHub"),
            action: .github,
            accessibilityIdentifier: "SidebarHelpMenuOptionGitHub"
        ))
        menu.addItem(helpItem(
            title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
            action: .githubIssues,
            accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues"
        ))
        menu.addItem(helpItem(
            title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
            action: .discord,
            accessibilityIdentifier: "SidebarHelpMenuOptionDiscord"
        ))
        menu.addItem(.separator())
        menu.addItem(callbackItem(
            title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            selector: #selector(checkForUpdates(_:)),
            accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates"
        ))
        return menu
    }

    private func helpItem(
        title: String,
        action: Action,
        accessibilityIdentifier: String
    ) -> NSMenuItem {
        let item = callbackItem(
            title: title,
            selector: #selector(performHelpAction(_:)),
            accessibilityIdentifier: accessibilityIdentifier
        )
        item.representedObject = action.rawValue
        return item
    }

    private func callbackItem(
        title: String,
        selector: Selector,
        accessibilityIdentifier: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        return item
    }

    @objc private func performHelpAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = Action(rawValue: rawValue) else { return }
        callbacks.onHelpAction(action)
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        _ = sender
        callbacks.onCheckForUpdates()
    }

    @objc private func sendFeedback(_ sender: NSMenuItem) {
        _ = sender
        callbacks.onSendFeedback()
    }
}
