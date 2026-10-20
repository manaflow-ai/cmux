import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings

/// Feeds the palette's workspace and tab pages from the daemon store.
enum PaletteSourcesBridge {
    static func make(services: AppServices) -> PaletteSources {
        var sources = makeBase(services: services)
        // A typed path or web address: Open it, or Ask Agent about it (Cmd-P and Cmd-Shift-P).
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
    /// owner; rename prompts also start from the titles listed here.
    static func targetSource(_ services: AppServices) -> any PaletteTargetSource {
        let windows = WindowTargetSource(services: services)
        let profiles = BrowserProfileTargetSource(services: services, next: windows)
        let screens = ScreenTargetSource(services: services, next: profiles)
        let tabs = TabAndGroupTargetSource(services: services, next: screens)
        return SidebarSectionTargetSource(services: services, next: tabs)
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
            return services.machines.allWorkspaces.map(\.0).map { workspace in
                let cwd = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.cwd != nil }?.cwd
                return PaletteWorkspace(id: workspace.id, title: workspace.displayName, directory: cwd,
                                        isSelected: workspace.id == shown, unreadCount: workspace.unreadCount,
                                        groupName: groupNames[workspace.id])
            }
        }

        func selectWorkspace(id: String) {
            guard let state = services.windows.active?.state else { return }
            services.windows.show(workspaceID: id, in: state)
        }

        func renameWorkspace(id: String, to title: String) {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key else { return }
            daemon.send("rename-workspace") { connection in _ = try await connection.renameWorkspace(key, to: title) }
        }

        func closeWorkspace(id: String) {
            guard let (workspace, daemon) = services.machines.workspace(id: id), let key = workspace.key else { return }
            guard !HomeRules.isHome(workspace) else { return services.registry.refuse(RefusalStrings.homeNotClosable) }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            daemon.send("close-workspace") { connection in try await WorkspaceClose.close(key, terminals: terminals, on: connection) }
        }
    }

    final class TabSource: PaletteTabSource {
        private unowned let services: AppServices
        init(services: AppServices) { self.services = services }

        var tabs: [PaletteTab] {
            let selected = services.windows.active?.focusedPane?.selectedTab?.id
            return services.machines.allWorkspaces.map(\.0).flatMap { workspace in
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                    PaletteTab(id: tab.id, title: tab.displayTitle.isEmpty ? Strings.untitledTerminal : tab.displayTitle,
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
            guard let (tab, pane) = services.locateTab(id) else { return }
            let surface = tab.surface
            services.daemon(for: pane).send("rename-surface") { connection in try await connection.renameTab(surface, to: title) }
        }

        func closeTab(id: String) {
            guard let (_, pane) = services.locateTab(id), let controller = services.paneController(for: pane) else { return }
            controller.close([StripTabID(id)])
        }
    }
}
