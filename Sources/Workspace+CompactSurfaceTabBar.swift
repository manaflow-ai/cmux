import AppKit
import Bonsplit

/// Wires ``CompactSurfaceTabBarCluster`` into the workspace's Bonsplit tab
/// bars: per-pane button lists, the "+" click, and the cluster menus. Every
/// menu row calls the same entrypoint its keyboard shortcut and command
/// palette entry use.
extension Workspace {
    /// Availability gates read when buttons are applied or a menu opens, so a
    /// feature flag or browser setting flip shows up without a restart.
    func compactSurfaceTabBarAvailability() -> CompactSurfaceTabBarCluster.Availability {
        CompactSurfaceTabBarCluster.Availability(
            agentChat: Self.surfaceTabBarBuiltInActionIsAvailable(.newAgentChat)
                && BrowserAvailabilitySettings.isEnabled(),
            browser: Self.surfaceTabBarBuiltInActionIsAvailable(.newBrowser),
            files: RightSidebarMode.files.isAvailable()
        )
    }

    /// Whether the pane's selected tab is an agent chat page. Agent chat is a
    /// browser surface pointed at the agent chat server, so this matches the
    /// page URL against the app-owned server and the configured server URL.
    func compactSurfaceTabBarPaneContent(inPane pane: PaneID) -> CompactSurfaceTabBarCluster.PaneContent {
        guard CmuxFeatureFlags.shared.isAgentChatUIEnabled,
              let tabId = bonsplitController.selectedTabId(inPane: pane),
              let panelId = panelIdFromSurfaceId(tabId),
              let browser = browserPanel(for: panelId) else {
            return .standard
        }
        return CompactSurfaceTabBarCluster.isAgentChatURL(
            browser.currentURL,
            agentChatBaseURLs: compactSurfaceTabBarAgentChatBaseURLs()
        ) ? .agentChat : .standard
    }

    private func compactSurfaceTabBarAgentChatBaseURLs() -> [URL] {
        var urls: [URL] = []
        if let session = AgentChatActionInFlightGate.ownedServerSession() {
            urls.append(session.browserURL)
        }
        let configured = owningTabManager
            .flatMap { AppDelegate.shared?.mainWindowContext(for: $0)?.cmuxConfigStore?.agentChat }
            ?? .default
        urls.append(configured.url)
        return urls
    }

    // MARK: - Pane policy

    /// Buttons for a pane showing `content`: "+", split, and "..." for
    /// standard panes; agent chat panes drop the split button.
    func compactSurfaceTabBarButtonIDs(for content: CompactSurfaceTabBarCluster.PaneContent) -> [String] {
        switch content {
        case .standard:
            return [
                CompactSurfaceTabBarCluster.addButtonID,
                CompactSurfaceTabBarCluster.splitButtonID,
                CompactSurfaceTabBarCluster.moreButtonID
            ]
        case .agentChat:
            return [CompactSurfaceTabBarCluster.addButtonID, CompactSurfaceTabBarCluster.moreButtonID]
        }
    }

    /// What a plain click on "+" creates: a terminal, as Cmd-T does. Agent
    /// Chat stays in the "+" menu.
    var compactSurfaceTabBarAddClickItem: CompactSurfaceTabBarCluster.Item { .terminal }

    func compactSurfaceTabBarButtons(
        for content: CompactSurfaceTabBarCluster.PaneContent,
        availability: CompactSurfaceTabBarCluster.Availability
    ) -> [BonsplitConfiguration.SplitActionButton] {
        compactSurfaceTabBarButtonIDs(for: content).compactMap { id in
            compactSurfaceTabBarButton(id: id, availability: availability)
        }
    }

    private func compactSurfaceTabBarButton(
        id: String,
        availability: CompactSurfaceTabBarCluster.Availability
    ) -> BonsplitConfiguration.SplitActionButton? {
        switch id {
        case CompactSurfaceTabBarCluster.addButtonID:
            let tooltip = String(localized: "surfaceTabBar.compact.add.tooltip.terminal", defaultValue: "New Terminal")
            return BonsplitConfiguration.SplitActionButton(
                id: id,
                systemImage: "plus",
                tooltip: tooltip,
                action: .custom(id),
                menuBehavior: .secondary,
                offersNewTerminal: true
            )
        case CompactSurfaceTabBarCluster.splitButtonID:
            return BonsplitConfiguration.SplitActionButton(
                id: id,
                systemImage: "square.split.2x1",
                tooltip: String(
                    localized: "surfaceTabBar.compact.split.tooltip",
                    defaultValue: "Split Right (Option-click to Split Down)"
                ),
                action: .splitRight,
                alternateAction: .splitDown,
                menuBehavior: .secondary
            )
        case CompactSurfaceTabBarCluster.moreButtonID:
            return BonsplitConfiguration.SplitActionButton(
                id: id,
                systemImage: "ellipsis",
                tooltip: String(localized: "surfaceTabBar.compact.more.tooltip", defaultValue: "More Actions"),
                action: .custom(id),
                menuBehavior: .primary
            )
        default:
            return nil
        }
    }

    /// Rows of the menu for `buttonID`, or nil when the button has no menu.
    func compactSurfaceTabBarMenuItems(
        forButton buttonID: String,
        content: CompactSurfaceTabBarCluster.PaneContent,
        availability: CompactSurfaceTabBarCluster.Availability
    ) -> [CompactSurfaceTabBarCluster.Item]? {
        switch buttonID {
        case CompactSurfaceTabBarCluster.addButtonID:
            var items: [CompactSurfaceTabBarCluster.Item] = []
            if availability.agentChat { items.append(.agentChat) }
            items.append(.terminal)
            if availability.browser { items.append(.browser) }
            return items
        case CompactSurfaceTabBarCluster.splitButtonID:
            return [.splitRight, .splitDown]
        case CompactSurfaceTabBarCluster.moreButtonID:
            var items: [CompactSurfaceTabBarCluster.Item] = []
            if content == .agentChat {
                items.append(contentsOf: [.splitRight, .splitDown, .separator])
            }
            if availability.files { items.append(.files) }
            items.append(contentsOf: [.openFolder, .newWindow])
            return items
        default:
            return nil
        }
    }

    // MARK: - Applying

    /// Re-resolves every pane's buttons. Panes showing an agent chat get the
    /// two-button override; every other pane uses the workspace-wide cluster.
    func refreshCompactSurfaceTabBarButtons() {
        for pane in bonsplitController.allPaneIds {
            refreshCompactSurfaceTabBarButtons(inPane: pane)
        }
    }

    func refreshCompactSurfaceTabBarButtons(inPane pane: PaneID) {
        guard surfaceTabBarUsesCompactCluster else {
            bonsplitController.setSplitButtons(nil, forPane: pane)
            return
        }
        switch compactSurfaceTabBarPaneContent(inPane: pane) {
        case .standard:
            bonsplitController.setSplitButtons(nil, forPane: pane)
        case .agentChat:
            bonsplitController.setSplitButtons(
                compactSurfaceTabBarButtons(
                    for: .agentChat,
                    availability: compactSurfaceTabBarAvailability()
                ),
                forPane: pane
            )
        }
    }

    /// Handles a click on a cluster button routed through Bonsplit's custom
    /// action path. Returns false for identifiers the cluster does not own.
    func handleCompactSurfaceTabBarCustomAction(_ identifier: String, inPane pane: PaneID) -> Bool {
        guard surfaceTabBarUsesCompactCluster else { return false }
        switch identifier {
        case CompactSurfaceTabBarCluster.addButtonID:
            performCompactSurfaceTabBarItem(compactSurfaceTabBarAddClickItem, inPane: pane)
            return true
        case CompactSurfaceTabBarCluster.moreButtonID, CompactSurfaceTabBarCluster.splitButtonID:
            // "..." only opens its menu; Bonsplit presents it directly.
            return true
        default:
            return false
        }
    }

    func compactSurfaceTabBarMenu(forButton buttonID: String, inPane pane: PaneID) -> NSMenu? {
        guard surfaceTabBarUsesCompactCluster,
              let items = compactSurfaceTabBarMenuItems(
                  forButton: buttonID,
                  content: compactSurfaceTabBarPaneContent(inPane: pane),
                  availability: compactSurfaceTabBarAvailability()
              ),
              !items.isEmpty else {
            return nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item == .separator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = SidebarRowClosureMenuItem(title: item.title) { [weak self] in
                self?.performCompactSurfaceTabBarItem(item, inPane: pane)
            }
            if let shortcutAction = item.shortcutAction {
                let shortcut = KeyboardShortcutSettings.menuShortcut(for: shortcutAction)
                if let keyEquivalent = shortcut.menuItemKeyEquivalent {
                    menuItem.keyEquivalent = keyEquivalent
                    menuItem.keyEquivalentModifierMask = shortcut.modifierFlags
                }
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    func performCompactSurfaceTabBarItem(_ item: CompactSurfaceTabBarCluster.Item, inPane pane: PaneID) {
        guard bonsplitController.allPaneIds.contains(pane) else { return }
        let presentingWindow = NSApp.keyWindow ?? NSApp.mainWindow
        switch item {
        case .agentChat:
            openAgentChatTab(inPane: pane, presentingWindow: presentingWindow)
        case .terminal:
            // Same path as the tab bar's built-in new-terminal button.
            bonsplitController.requestNewTab(kind: "terminal", inPane: pane)
        case .browser:
            bonsplitController.requestNewTab(kind: "browser", inPane: pane)
        case .splitRight:
            bonsplitController.splitPane(pane, orientation: .horizontal)
        case .splitDown:
            bonsplitController.splitPane(pane, orientation: .vertical)
        case .files:
            if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .files,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            ) != true {
                NSSound.beep()
            }
        case .openFolder:
            AppDelegate.shared?.showOpenFolderPanel(
                preferredWindow: presentingWindow,
                tabManager: owningTabManager
            )
        case .newWindow:
            AppDelegate.shared?.openNewMainWindow(preferredWindow: presentingWindow)
        case .separator:
            break
        }
    }
}
