import CmuxNextActions

extension RegistryPaletteProvider {
    /// A stable empty-query vocabulary. Adding a catalog action never lengthens the root;
    /// the complete catalog remains available to typed search and the Commands scope.
    static let rootIntentIDs: Set<ActionID> = [
        "newTab", "newTab.default", "newWindow", "closeTab", "closeWorkspace",
        "closePane", "splitRight", "splitDown", "openBrowser", "palette.newAgentChat",
        "palette.quickAgentChat", "openSettings", "goToWorkspace", "tab.search", "search.chats",
        "globalSearch", "find", "findInDirectory", "renameWorkspace", "renameTab",
        "toggleSidebar", "toggleSplitZoom", "equalizeSplits", "openFolder",
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
        "toggleTerminalCopyMode", "palette.terminalOpenDirectory", "terminal.runLastCommandAgain", "resetTerminal", "browserBack", "browserForward",
        "browserReload", "browserStop", "browserZoomIn", "browserZoomOut", "browserZoomReset",
        "browser.copyURL", "browser.downloads.show", "browserShowHistory", "agentPane.searchChats", "agentPane.searchFiles",
        "agentPane.switchModel", "agentPane.archiveChat", "agentPane.continueIn", "agentPane.createCheckpoint", "agentPane.git.commit",
        "agentPane.git.push", "newCloudMachine", "cloudSSH", "remote.reconnect", "agent.harness.add", "macScreen.open",
    ]

    static let rootFamilies: [(category: ActionCategory, members: Set<ActionCategory>, symbol: String)] = [
        (.window, [.window, .pane, .screen, .other], "rectangle.split.2x2"),
        (.workspace, [.workspace, .sidebar], "rectangle.stack"),
        (.tab, [.tab], "rectangle.on.rectangle"),
        (.browser, [.browser], "globe"),
        (.terminal, [.terminal], "terminal"),
        (.agents, [.agents], "bubble.left.and.bubble.right"),
        (.cloud, [.cloud, .remote], "cloud"),
        (.settings, [.settings, .notifications], "gearshape"),
    ]

    /// Each root family's section ids, in ``rootFamilies``' order: the rows `curatedRootItems` reads for its row.
    static let rootFamilySectionIDs: [Set<String>] = rootFamilies.map { Set($0.members.map(\.paletteSectionID)) }

    /// The root families (indices into ``rootFamilies``) whose row reads a section id's rows.
    static let rootFamiliesBySectionID: [String: [Int]] = {
        var families: [String: [Int]] = [:]
        for (index, sections) in rootFamilySectionIDs.enumerated() {
            for section in sections { families[section, default: []].append(index) }
        }
        return families
    }()

    /// Changes empty-query visibility without rebuilding action rows, aliases, targets or effects. `eligible`: the
    /// listed actions the root may show (bound or served by the palette, not debug-only). A family's page lists its
    /// members when it opens, not on every open.
    ///
    /// A family's page is made from the root list itself (``rootFamilyMembers(_:sections:folded:)``), which the rows
    /// keep (`RegistryPaletteRows.arranged`), not from `items`: each family row's command captured `items` whole, so
    /// the idle app kept a second copy of every command row (1,162 rows, 2 MB) beside the root's (CMUX-571).
    func curatedRootItems(_ items: [PaletteItem], eligible: Set<ActionID>) -> [PaletteItem] {
        // The family rows are appended after the action rows: sized for them up front, the list is not copied into a
        // buffer twice its size by the first append (a 4 MB buffer for 1,170 rows, CMUX-571).
        var root: [PaletteItem] = []
        root.reserveCapacity(items.count + Self.rootFamilies.count)
        for var item in items {
            item.hidesWhenQueryEmpty = item.actionID.map {
                !Self.rootIntentIDs.contains($0) || !eligible.contains($0)
            } ?? true
            root.append(item)
        }
        // What `items` hid on the empty query (folded family members): a family's page shows them so again.
        let folded = Set(items.lazy.filter(\.hidesWhenQueryEmpty).map(\.id))
        let section = PaletteSection(id: "rootFamilies", title: PaletteStrings.commandsTitle, order: -100)
        for (family, sections) in zip(Self.rootFamilies, Self.rootFamilySectionIDs) {
            // Retain the existing detailed families and their folded members in the drilldown.
            var listsEligible = false, anyEnabled = false
            for item in items where sections.contains(item.section.id) {
                if !listsEligible, let id = item.actionID, eligible.contains(id) { listsEligible = true }
                if item.isEnabled { anyEnabled = true }
                if listsEligible && anyEnabled { break }
            }
            guard listsEligible else { continue }
            let id = "rootFamily:\(family.category.rawValue)"
            var row = PaletteItem(
                id: id,
                title: family.category.title,
                symbol: family.symbol,
                section: section,
                isEnabled: anyEnabled,
                primary: PaletteCommand(id: "open", title: PaletteStrings.open, symbol: "arrow.right",
                                        effect: .deferred { [weak rows = self.rows] in
                                            .push(PalettePageSpec(
                                                id: id, title: family.category.title, placeholder: PaletteStrings.searchPlaceholder,
                                                symbol: family.symbol,
                                                providers: [StaticPaletteProvider(id: id, items: Self.rootFamilyMembers(
                                                    rows?.arranged[true]?.items ?? [], sections: sections, folded: folded))]
                                            ))
                                        })
            )
            row.hidesWhenTyping = true
            root.append(row)
        }
        return root
    }

    /// A root family's page rows: the root list's rows in the family's sections, in its order, each hidden on the empty
    /// query as the arrangement hid it (`folded`: family members, shown folded into their family row). The root list
    /// differs from the arrangement only in that flag, so these are the rows the arrangement listed for those sections.
    static func rootFamilyMembers(_ root: [PaletteItem], sections: Set<String>, folded: Set<String>) -> [PaletteItem] {
        root.compactMap { item in
            guard sections.contains(item.section.id) else { return nil }
            var item = item
            item.hidesWhenQueryEmpty = folded.contains(item.id)
            return item
        }
    }
}
