import Bonsplit
import Foundation

/// The compact pane tab bar button cluster used when `cmux.json` does not set
/// `surfaceTabBarButtons` / `ui.surfaceTabBar.buttons`.
///
/// At most three buttons: "+" (click creates the primary new surface,
/// right-click or press-and-hold lists every new-surface kind), split (click
/// splits right, Option-click splits down, right-click or hold lists both),
/// and "..." (click lists the remaining pane actions). Agent chat panes drop
/// the split button and list the splits in "..." instead.
///
/// Every row resolves to an existing action with its own keyboard shortcut
/// and command palette entry; this type only decides which rows appear.
enum CompactSurfaceTabBarCluster {
    static let addButtonID = "cmux.compactTabBar.add"
    static let splitButtonID = "cmux.compactTabBar.split"
    static let moreButtonID = "cmux.compactTabBar.more"

    /// What the pane's selected tab shows, as far as the cluster cares.
    enum PaneContent: Equatable, Sendable {
        case standard
        case agentChat
    }

    /// One row of a cluster menu, or the click action of the "+" button.
    enum Item: Equatable, Sendable {
        case agentChat
        case terminal
        case browser
        case splitRight
        case splitDown
        case files
        case openFolder
        case newWindow
        case separator

        var title: String {
            switch self {
            case .agentChat:
                return String(localized: "surfaceTabBar.compact.menu.agentChat", defaultValue: "Agent Chat")
            case .terminal:
                return String(localized: "surfaceTabBar.compact.menu.terminal", defaultValue: "Terminal")
            case .browser:
                return String(localized: "surfaceTabBar.compact.menu.browser", defaultValue: "Browser")
            case .splitRight:
                return String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")
            case .splitDown:
                return String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")
            case .files:
                return RightSidebarMode.files.label
            case .openFolder:
                return String(localized: "menu.file.openFolder", defaultValue: "Open Folder…")
            case .newWindow:
                return String(localized: "menu.file.newWindow", defaultValue: "New Window")
            case .separator:
                return ""
            }
        }

        /// The user-editable shortcut that performs the same action, shown as
        /// the menu row's key equivalent. Nil when the action has none.
        var shortcutAction: KeyboardShortcutSettings.Action? {
            switch self {
            case .agentChat: return CmuxSurfaceTabBarBuiltInAction.newAgentChat.shortcutAction
            case .terminal: return CmuxSurfaceTabBarBuiltInAction.newTerminal.shortcutAction
            case .browser: return CmuxSurfaceTabBarBuiltInAction.newBrowser.shortcutAction
            case .splitRight: return CmuxSurfaceTabBarBuiltInAction.splitRight.shortcutAction
            case .splitDown: return CmuxSurfaceTabBarBuiltInAction.splitDown.shortcutAction
            case .files: return RightSidebarMode.files.shortcutAction
            case .openFolder: return .openFolder
            case .newWindow: return .newWindow
            case .separator: return nil
            }
        }
    }

    /// Availability inputs, resolved by the caller when a menu opens or the
    /// buttons are applied, so feature flag and setting flips take effect.
    struct Availability: Equatable, Sendable {
        var agentChat: Bool
        var browser: Bool
        var files: Bool

        init(agentChat: Bool, browser: Bool, files: Bool = true) {
            self.agentChat = agentChat
            self.browser = browser
            self.files = files
        }
    }

    // MARK: - Buttons

    static func buttonIDs(for content: PaneContent) -> [String] {
        switch content {
        case .standard:
            return [addButtonID, splitButtonID, moreButtonID]
        case .agentChat:
            return [addButtonID, moreButtonID]
        }
    }

    /// What a plain click on "+" creates: an agent chat when it is available,
    /// otherwise a terminal.
    static func addClickItem(availability: Availability) -> Item {
        availability.agentChat ? .agentChat : .terminal
    }

    static func bonsplitButtons(
        for content: PaneContent,
        availability: Availability
    ) -> [BonsplitConfiguration.SplitActionButton] {
        buttonIDs(for: content).compactMap { id in
            bonsplitButton(id: id, availability: availability)
        }
    }

    private static func bonsplitButton(
        id: String,
        availability: Availability
    ) -> BonsplitConfiguration.SplitActionButton? {
        switch id {
        case addButtonID:
            let tooltip: String
            switch addClickItem(availability: availability) {
            case .agentChat:
                tooltip = String(localized: "surfaceTabBar.compact.add.tooltip.agentChat", defaultValue: "New Agent Chat")
            default:
                tooltip = String(localized: "surfaceTabBar.compact.add.tooltip.terminal", defaultValue: "New Terminal")
            }
            return BonsplitConfiguration.SplitActionButton(
                id: addButtonID,
                systemImage: "plus",
                tooltip: tooltip,
                action: .custom(addButtonID),
                menuBehavior: .secondary,
                offersNewTerminal: true
            )
        case splitButtonID:
            return BonsplitConfiguration.SplitActionButton(
                id: splitButtonID,
                systemImage: "square.split.2x1",
                tooltip: String(
                    localized: "surfaceTabBar.compact.split.tooltip",
                    defaultValue: "Split Right (Option-click to Split Down)"
                ),
                action: .splitRight,
                alternateAction: .splitDown,
                menuBehavior: .secondary
            )
        case moreButtonID:
            return BonsplitConfiguration.SplitActionButton(
                id: moreButtonID,
                systemImage: "ellipsis",
                tooltip: String(localized: "surfaceTabBar.compact.more.tooltip", defaultValue: "More Actions"),
                action: .custom(moreButtonID),
                menuBehavior: .primary
            )
        default:
            return nil
        }
    }

    // MARK: - Menus

    /// Rows of the menu for `buttonID`, or nil when the button has no menu.
    static func menuItems(
        forButton buttonID: String,
        content: PaneContent,
        availability: Availability
    ) -> [Item]? {
        switch buttonID {
        case addButtonID:
            return addMenuItems(availability: availability)
        case splitButtonID:
            return [.splitRight, .splitDown]
        case moreButtonID:
            return moreMenuItems(content: content, availability: availability)
        default:
            return nil
        }
    }

    static func addMenuItems(availability: Availability) -> [Item] {
        var items: [Item] = []
        if availability.agentChat { items.append(.agentChat) }
        items.append(.terminal)
        if availability.browser { items.append(.browser) }
        return items
    }

    static func moreMenuItems(content: PaneContent, availability: Availability) -> [Item] {
        var items: [Item] = []
        if content == .agentChat {
            items.append(contentsOf: [.splitRight, .splitDown, .separator])
        }
        if availability.files { items.append(.files) }
        items.append(contentsOf: [.openFolder, .newWindow])
        return items
    }

    // MARK: - Agent chat detection

    /// Whether `url` is a page served by an agent chat server rooted at one of
    /// `agentChatBaseURLs`: same scheme, loopback-normalized host and port, and
    /// a path inside the base path (the app-owned server puts its token there).
    static func isAgentChatURL(_ url: URL?, agentChatBaseURLs: [URL]) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let origin = Origin(components) else {
            return false
        }
        return agentChatBaseURLs.contains { base in
            guard let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
                  let baseOrigin = Origin(baseComponents),
                  baseOrigin == origin else {
                return false
            }
            let basePath = trimmedTrailingSlash(baseComponents.path)
            guard !basePath.isEmpty else { return true }
            let path = components.path
            return path == basePath || path.hasPrefix(basePath + "/")
        }
    }

    private struct Origin: Equatable {
        var scheme: String
        var host: String
        var port: Int

        init?(_ components: URLComponents) {
            guard let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let rawHost = components.host?.lowercased(),
                  !rawHost.isEmpty else {
                return nil
            }
            self.scheme = scheme
            self.host = rawHost == "localhost" ? "127.0.0.1" : rawHost
            self.port = components.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    private static func trimmedTrailingSlash(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
