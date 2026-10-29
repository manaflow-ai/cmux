import CmuxNextActions

extension RegistryPaletteProvider {
    /// A stable empty-query vocabulary. Adding a catalog action never lengthens the root;
    /// the complete catalog remains available to typed search and the Commands scope.
    private static let rootIntentIDs: Set<ActionID> = [
        "newTab", "newTab.default", "newWindow", "closeTab", "closeWorkspace",
        "closePane", "splitRight", "splitDown", "openBrowser", "palette.newAgentChat",
        "palette.quickAgentChat", "openSettings", "goToWorkspace", "tab.search", "search.chats",
        "globalSearch", "find", "findInDirectory", "renameWorkspace", "renameTab",
        "toggleSidebar", "toggleRightSidebar", "toggleSplitZoom", "equalizeSplits", "openFolder",
        "file.open", "reopenClosedBrowserPanel", "reopenClosedWorkspace", "recentlyClosed", "jumpToUnread",
        "openDiffViewer", "terminal.setTheme", "appearance.customize", "appearance.changeBackground", "terminal.increaseFontSize",
        "terminal.decreaseFontSize", "remote.connect", "workspace.newOnMachine", "newCloudWorkspace", "keybindings.open",
        "palette.checkForUpdates", "palette.toggleSetting", "reloadConfiguration", "closeWindow", "minimizeWindow",
        "zoomWindow", "toggleFullScreen", "focusHistoryBack", "focusHistoryForward", "history.search",
        "history.show", "home.show", "home.newMessage", "quit", "palette.openTaskManager",
        "palette.toggleWorkspacePin", "palette.workspaceColor", "palette.workspaceStatus", "workspace.setTheme", "workspace.copyPath",
        "revealWorkspaceInFinder", "newWorkspaceGroup", "groupSelectedWorkspaces", "workspace.selectLastUsed", "markWorkspaceDone",
        "reconnectWorkspace", "saveLayoutTemplate", "palette.layout.open", "space.new", "space.switch",
        "splitLeft", "splitUp", "renamePane", "focusLeft", "focusRight",
        "focusUp", "focusDown", "focusNextPane", "focusPreviousPane", "newColumn", "newColumnLeft",
        "newRow", "layout.undo", "toggleCanvasLayout", "duplicateTab", "reloadTab",
        "palette.toggleTabPin", "newSurface", "nextSurface", "prevSurface", "focusLocation",
        "tab.muteAudio", "tab.unmuteAudio", "tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab",
        "tabGroup.rename", "hibernateTab", "wakeTab", "terminal.resetFontSize", "terminal.clear",
        "terminalCopy", "terminalPaste", "terminal.selectAll", "findNext", "findPrevious",
        "toggleTerminalCopyMode", "palette.terminalOpenDirectory", "resetTerminal", "browserBack", "browserForward",
        "browserReload", "browserStop", "browserZoomIn", "browserZoomOut", "browserZoomReset",
        "browser.copyURL", "browser.downloads.show", "browserShowHistory", "agentPane.searchChats", "agentPane.searchFiles",
        "agentPane.switchModel", "agentPane.archiveChat", "agentPane.continueIn", "agentPane.createCheckpoint", "agentPane.git.commit",
        "agentPane.git.push", "newCloudMachine", "cloudSSH", "remote.reconnect", "agent.harness.add",
    ]

    private static let rootFamilies: [(category: ActionCategory, members: Set<ActionCategory>, symbol: String)] = [
        (.window, [.window, .pane, .screen, .other], "rectangle.split.2x2"),
        (.workspace, [.workspace, .sidebar], "rectangle.stack"),
        (.tab, [.tab], "rectangle.on.rectangle"),
        (.browser, [.browser], "globe"),
        (.terminal, [.terminal], "terminal"),
        (.agents, [.agents], "bubble.left.and.bubble.right"),
        (.cloud, [.cloud, .remote], "cloud"),
        (.settings, [.settings, .notifications], "gearshape"),
    ]

    /// Changes empty-query visibility without rebuilding action rows, aliases, targets or effects.
    func curatedRootItems(_ items: [PaletteItem]) -> [PaletteItem] {
        let eligible = Set(registry.entries.filter {
            !$0.descriptor.isDebugOnly && ($0.isBound || effectOverrides[$0.id] != nil)
        }.map(\.id))
        var root = items.map { item in
            var item = item
            item.hidesWhenQueryEmpty = item.actionID.map {
                !Self.rootIntentIDs.contains($0) || !eligible.contains($0)
            } ?? true
            return item
        }
        let section = PaletteSection(id: "rootFamilies", title: PaletteStrings.commandsTitle, order: -100)
        for family in Self.rootFamilies {
            let sections = Set(family.members.map(\.paletteSectionID))
            // Retain the existing detailed families and their folded members in the drilldown.
            let members = items.filter { sections.contains($0.section.id) }
            guard members.contains(where: { $0.actionID.map { eligible.contains($0) } ?? false }) else { continue }
            let id = "rootFamily:\(family.category.rawValue)"
            var row = PaletteItem(
                id: id,
                title: family.category.title,
                symbol: family.symbol,
                section: section,
                isEnabled: members.contains(where: \.isEnabled),
                primary: PaletteCommand(id: "open", title: PaletteStrings.open, symbol: "arrow.right",
                                        effect: .deferred {
                                            .push(PalettePageSpec(
                                                id: id, title: family.category.title, placeholder: PaletteStrings.searchPlaceholder,
                                                symbol: family.symbol,
                                                providers: [StaticPaletteProvider(id: id, items: members)]
                                            ))
                                        })
            )
            row.hidesWhenTyping = true
            root.append(row)
        }
        return root
    }
}
