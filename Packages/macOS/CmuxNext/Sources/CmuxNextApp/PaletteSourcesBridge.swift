import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSidebar

/// Feeds the palette's workspace and tab pages from the daemon store.
enum PaletteSourcesBridge {
    static func make(services: AppServices) -> PaletteSources {
        var sources = makeBase(services: services)
        // Search (Cmd-Shift-A and the sidebar's Search button, plans/cmux-next/sidebar-search.md): history by
        // kind and the agent chats join the palette's own sources. Cmd-P lists only the open items. Agent chats
        // and agent sessions also make up the Chats & agents scope.
        sources.searchContributions = HistoryPalettePages.searchContributions(services) + [
            PaletteSearchContribution(id: "agentChats", title: AgentChatsPalettePage.title, order: 30, searchesChats: true) { [weak services] in
                services.map { AgentChatsPalettePage(services: $0).page() }
            },
        ]
        // A typed path or web address: Open it, or Ask Agent about it (Cmd-P, Cmd-Shift-P and Search).
        sources.goTo = AppPaletteGoToSource(services: services)
        // cmux.json `palette.scopes.<id>.prefix`, read on every open.
        sources.scopePrefixes = { [weak services] in
            let assigned = services?.settings?.snapshot.paletteScopePrefixes.assigned ?? [:]
            return Dictionary(uniqueKeysWithValues: assigned.map { (PaletteScopeID($0.key), $0.value) })
        }
        // cmux.json `palette.aliases` and `palette.pins`, read on every open.
        sources.rankSettings = { [weak services] in
            guard let services else { return PaletteRankSettings() }
            let setting = PaletteRankingSetting(services.settings?.fileRoot ?? .object([:]))
            // A renamed action's former id still names it.
            let canonical = { (id: String) in services.registry.canonicalID(for: ActionID(rawValue: id)).rawValue }
            var aliases: [String: [String]] = [:]
            for (id, words) in setting.aliases { aliases[canonical(id), default: []] += words }
            var seen = Set<String>()
            return PaletteRankSettings(aliases: aliases, pins: setting.pins.map(canonical).filter { seen.insert($0).inserted })
        }
        // Theme rows draw the theme's swatch strip (R98), from the catalog's
        // cache (read off the main thread at launch).
        sources.argumentSwatches = { [weak services] source, value in
            guard source == ActionSuggestions.ghosttyThemes else { return [] }
            return services?.themes.catalog.swatches(for: value) ?? []
        }
        return sources
    }

    private static func makeBase(services: AppServices) -> PaletteSources {
        PaletteSources(workspaces: WorkspaceSource(services: services), tabs: TabSource(services: services),
                       navigation: AppPaletteNavigationSource(services: services),
                       targets: targetSource(services),
                       context: { [weak services] in services.map(capturedTargets) ?? [] },
                       // Theme pickers preview the highlighted theme live.
                       argumentPreview: { [weak services] action, _, value, target in
                           services?.themes.pickerPreview(action, value: value, target: target)
                       })
    }

    /// Target lists for the palette's argument pages, each kind from its
    /// owner; rename prompts also start from the titles listed here. Tab
    /// groups come first: their source narrows the list for the saved-group
    /// actions (`targets(of:for:)`). `chats` lists the Priority view's
    /// chats; a test passes its own.
    static func targetSource(_ services: AppServices, chats: AgentPriorityChats = .app) -> any PaletteTargetSource {
        let windows = WindowTargetSource(services: services)
        let profiles = BrowserProfileTargetSource(services: services, next: windows)
        let screens = ScreenTargetSource(services: services, next: profiles)
        let spaces = SpaceAndPaneTargetSource(services: services, next: screens)
        let sections = SidebarSectionTargetSource(services: services, next: spaces)
        let groups = TabAndGroupTargetSource(services: services, next: PriorityChatTargetSource(chats: chats, next: sections))
        return agentChatTargets(AgentChatDestinations(services: services), next: groups)
    }

    static func agentChatTargets(_ destinations: AgentChatDestinations, next: any PaletteTargetSource) -> any PaletteTargetSource {
        func option(_ row: AgentChatDestinations.Destination) -> PaletteTargetOption {
            PaletteTargetOption(id: row.id, title: row.title, subtitle: row.state, symbol: row.symbol, isEnabled: row.isReady)
        }
        // A slow acpmux never holds the picker: past the bound it shows "Other Macs not loaded yet",
        // then the peers when acpmux lists them (AgentChatDestinations.updates).
        return RefreshingPaletteTargetSource(kind: .machine, actions: ["palette.newAgentChat", "palette.newAgentChatOn"],
            initial: [option(destinations.local)], next: next, updates: { destinations.updates() }, option: option)
    }

    /// The active window's focused objects when the palette opens: the
    /// selected tab of the focused pane, its group, the pane, the shown
    /// screen, workspace and window.
    static func capturedTargets(_ services: AppServices) -> [ActionTargetRef] {
        guard let window = services.windows.active else { return [] }
        var refs: [ActionTargetRef] = []
        if let pane = window.focusedPane {
            if let selected = pane.stripModel.selectedID {
                if let group = pane.tab(selected)?.tabGroup { refs.append(ActionTargetRef(kind: .tabGroup, id: group.rawValue)) }
                refs.append(ActionTargetRef(kind: .tab, id: selected.rawValue))
            }
            refs.append(ActionTargetRef(kind: .pane, id: pane.paneKey))
        }
        if let content = window.content, let screen = content.layoutModel.activeScreenID {
            if let group = content.workspace.screens.first(where: { $0.id == screen.rawValue })?.group {
                refs.append(ActionTargetRef(kind: .screenGroup, id: group.rawValue))
            }
            refs.append(ActionTargetRef(kind: .screen, id: screen.rawValue))
        }
        if let workspace = window.state.workspaceID { refs.append(ActionTargetRef(kind: .workspace, id: workspace)) }
        refs.append(ActionTargetRef(kind: .window, id: window.state.id))
        return refs
    }

    final class WorkspaceSource: PaletteWorkspaceSource {
        private unowned let services: AppServices
        init(services: AppServices) { self.services = services }

        var workspaces: [PaletteWorkspace] {
            let shown = services.windows.active?.state.workspaceID
            var groupNames: [String: String] = [:]
            for group in AppPaletteNavigationSource.groups(services) {
                for id in group.workspaceIDs where groupNames[id] == nil { groupNames[id] = group.name }
            }
            let subagents = ChiefSubagentIDs.live
            return services.machines.allWorkspaces.map { workspace, daemon in // another machine's rows name it
                let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                let cwd = tabs.first { $0.cwd != nil }?.cwd
                // A Chief subagent's workspace is found by the id the Chief gave it (`a612`).
                let agentID = subagents.id(name: workspace.displayName, chats: tabs.compactMap(\.agentSession))
                // The local Chief runs on this Mac, as the sidebar's machine marks say.
                let onThisMac = daemon.isLocal || MachineID(daemon.machineID).isLocalChief
                // Named as its sidebar row is: a default-named workspace reads as its front tab.
                return PaletteWorkspace(id: workspace.id, title: services.shownWorkspaceName(workspace), directory: cwd,
                                        isSelected: workspace.id == shown, unreadCount: workspace.unreadCount,
                                        groupName: groupNames[workspace.id], machineName: onThisMac ? nil : services.machines.machineName(daemon.machineID),
                                        agentID: agentID)
            }
        }

        func selectWorkspace(id: String) {
            // No active window (all closed, CLI run): show it in its own window, else a new one.
            guard let window = services.windows.active else {
                services.windows.reveal(workspaceID: id)
                return
            }
            // Keep a workspace already listed in this window on the same selection path as a sidebar
            // click and the numbered navigation shortcuts, so its row highlight moves in the same turn.
            // A workspace owned by another window keeps the palette's global show behavior.
            if services.windows.registry.value.owner(of: id) == window.state.id {
                SidebarNavigation.activate(.workspace(WorkspaceID(id)), in: window, services)
            } else {
                services.windows.show(workspaceID: id, in: window.state)
            }
        }

        func renameWorkspace(id: String, to title: String) {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key else { return }
            daemon.send("rename-workspace") { connection in _ = try await connection.renameWorkspace(key, to: title) }
        }

        func closeWorkspace(id: String) {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key else { return }
            guard !HomeRules.isHome(workspace) else { return services.registry.refuse(RefusalStrings.homeNotClosable) }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            daemon.send("close-workspace") { connection in try await WorkspaceClose.close(key, terminals: terminals, on: connection, awaitingReplyOn: daemon) }
        }
    }

    final class TabSource: PaletteTabSource {
        private unowned let services: AppServices
        init(services: AppServices) { self.services = services }

        var tabs: [PaletteTab] {
            let selected = services.windows.active?.focusedPane?.selectedTab?.id
            // The strip's title rule: an agent chat by its chat, never its record's `about:blank`.
            var titles = TabTitleResolver(services: services)
            return services.machines.allWorkspaces.map(\.0).flatMap { workspace in
                titles.workspaceName = AgentChatTabTitle.workspaceName(workspace)
                return workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                    PaletteTab(id: tab.id, title: titles.title(tab),
                               workspaceTitle: workspace.displayName, kind: tab.kind == .browser ? .browser : .terminal,
                               isSelected: tab.id == selected)
                }
            }
        }

        /// Switch to tab: `tab.focus`, the one reveal that shows the tab's workspace and screen,
        /// selects the tab and focuses its pane. Selecting through the pane alone missed a tab in
        /// another workspace: the window swaps that workspace's content in on a later turn, so
        /// its pane was not there yet and the jump landed on the workspace (Leo 2026-10-19).
        func selectTab(id: String) {
            _ = services.registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
        }

        func renameTab(id: String, to title: String) {
            guard let (tab, pane) = services.locateTabOnAnyMachine(id) else { return }
            let surface = tab.surface
            services.daemon(for: pane).send("rename-surface") { connection in try await connection.renameTab(surface, to: title) }
        }

        func closeTab(id: String) {
            guard let (_, pane) = services.locateTabOnAnyMachine(id), let controller = services.paneController(for: pane) else { return }
            controller.close([StripTabID(id)])
        }
    }
}


extension AgentChatDestinations {
    init(services: AppServices) {
        let (host, machines) = (services.agentTabs.host, services.agentTabs.cloudMachines)
        self.init(localTitle: WorkspaceVerbStrings.thisMac, peers: { try await host.chatPeers() }, cloud: {
            await machines.list?() ?? .init(signedIn: false, loaded: false, machines: [])
        })
    }
}
