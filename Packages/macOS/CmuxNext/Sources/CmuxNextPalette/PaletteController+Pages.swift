import CmuxNextActions

extension PaletteController {
    // MARK: Pages

    /// The root command list: every catalog action plus workspaces, tabs,
    /// directories, and settings once the user types.
    public func commandsPage() -> PalettePageSpec {
        var providers: [any PaletteProvider] = [makeRegistryProvider()]
        if let source = sources.workspaces {
            providers.append(WorkspacePaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.tabs {
            providers.append(TabPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.recentDirectories {
            providers.append(RecentDirectoriesPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.settings {
            providers.append(SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        providers += sources.extraProviders
        let entry = model.scopeEntry
        if entry.listsScopesWhenTyping || entry.listsScopesWhenEmpty {
            providers.append(PaletteScopeListProvider(graph: model.navigation.graph, config: model.navigation.config, from: .root,
                                                      showsItemsForEmptyQuery: entry.listsScopesWhenEmpty))
        }
        var page = PalettePageSpec(
            id: "commands",
            title: PaletteStrings.commandsTitle,
            placeholder: PaletteStrings.searchPlaceholder,
            symbol: "command",
            providers: providers,
            showsRecent: true,
            scope: .root
        )
        page.mergesSectionsWhenTyping = true
        if let ask = sources.askAI {
            page.trailingQueryItems = { query in Self.askAIItems(query, ask: ask) }
        }
        return page
    }

    /// The root's Ask AI row for a typed query (cx-vtxi7). It goes after
    /// every match, so the palette stays a command list: the agent starts only
    /// when the person picks the row (first when nothing else matches).
    static func askAIItems(_ query: String, ask: @escaping @MainActor (String) -> Void) -> [PaletteItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let run = PaletteCommand(id: "askAI", title: PaletteStrings.askAICommand, symbol: "sparkles",
                                 effect: .perform { ask(text) })
        var item = PaletteItem(id: "palette.askAI", title: PaletteStrings.askAITitle(text), subtitle: PaletteStrings.askAISubtitle,
                               symbol: "sparkles", primary: run)
        // A different question each time: usage would rank nothing.
        item.frecencyKey = nil
        return [item]
    }

    /// Scope `commands` (`>`): catalog actions only.
    func commandsOnlyPage() -> PalettePageSpec {
        PalettePageSpec(id: "commandsOnly", title: PaletteStrings.commandsTitle, placeholder: PaletteStrings.searchPlaceholder,
                        symbol: "command", providers: [makeRegistryProvider()], showsRecent: true, scope: PaletteScopeID.commands)
    }

    /// Scope `scopes` (`?`): every scope, with its prefix and keyword.
    func scopeListPage() -> PalettePageSpec {
        PalettePageSpec(id: "scopes", title: PaletteStrings.scopesTitle, placeholder: PaletteStrings.scopesPlaceholder,
                        symbol: "square.grid.2x2",
                        providers: [PaletteScopeListProvider(graph: model.navigation.graph, config: model.navigation.config,
                                                             from: PaletteScopeID.scopes, showsItemsForEmptyQuery: true)],
                        scope: PaletteScopeID.scopes)
    }

    /// The page of a graph scope (`PaletteModel.scopePage`); `context` is
    /// the row a drill came from.
    func page(forScope id: PaletteScopeID, context: PaletteItem?) -> PalettePageSpec? {
        var page: PalettePageSpec?
        switch id {
        case .root: page = commandsPage()
        case PaletteScopeID.commands: page = commandsOnlyPage()
        case PaletteScopeID.tabs: page = sources.actionPages["tab.search"]?() ?? tabsPage()
        case PaletteScopeID.workspaces: page = workspacesPage()
        case PaletteScopeID.settings: page = settingsPage()
        case PaletteScopeID.shortcuts: page = keyboardShortcutsPage()
        case PaletteScopeID.scopes: page = scopeListPage()
        default: page = sources.scopes.first { $0.descriptor.id == id }?.page(context)
        }
        page?.scope = id
        return page
    }

    public func keyboardShortcutsPage() -> PalettePageSpec {
        PalettePageSpec(
            id: "shortcuts",
            title: PaletteStrings.shortcutsTitle,
            placeholder: PaletteStrings.shortcutsPlaceholder,
            symbol: "keyboard",
            providers: [{
                let provider = KeyboardShortcutsPaletteProvider(registry: registry)
                if shortcutRecorder.editor != nil { provider.editShortcut = { [weak self] in self?.shortcutRecorder.begin($0) } }
                return provider
            }()]
        )
    }

    public func workspacesPage() -> PalettePageSpec? {
        guard let source = sources.workspaces else { return nil }
        return PalettePageSpec(
            id: "workspaces",
            title: PaletteStrings.workspacesTitle,
            placeholder: PaletteStrings.workspacesPlaceholder,
            symbol: "rectangle.stack",
            providers: [WorkspacePaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    public func tabsPage() -> PalettePageSpec? {
        guard let source = sources.tabs else { return nil }
        return PalettePageSpec(
            id: "tabs",
            title: PaletteStrings.tabsTitle,
            placeholder: PaletteStrings.tabsPlaceholder,
            symbol: "rectangle.stack",
            providers: [TabPaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    func openInPage() -> PalettePageSpec? {
        guard let source = sources.openIn else { return nil }
        return PalettePageSpec(
            id: "openIn",
            title: PaletteStrings.openInTitle,
            placeholder: PaletteStrings.openInPlaceholder,
            symbol: "arrow.up.forward.app",
            providers: [OpenInPaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    func settingsPage() -> PalettePageSpec? {
        guard let source = sources.settings else { return nil }
        return PalettePageSpec(
            id: "settings",
            title: PaletteStrings.settingsTitle,
            placeholder: PaletteStrings.settingsPlaceholder,
            symbol: "switch.2",
            providers: [SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)]
        )
    }

    /// Registry provider with the palette-served actions: nested lists and
    /// inline rename entries backed by the sources.
    func makeRegistryProvider() -> RegistryPaletteProvider {
        let provider = RegistryPaletteProvider(registry: registry)
        if shortcutRecorder.editor != nil { provider.editShortcut = { [weak self] in self?.shortcutRecorder.begin($0) } }
        provider.targets = sources.targets
        provider.capturedTargets = capturedTargets
        provider.argumentPreview = sources.argumentPreview
        provider.argumentSwatches = sources.argumentSwatches
        provider.effectOverrides["palette.searchShortcuts"] = { [weak self] in
            self.map { .push($0.keyboardShortcutsPage()) }
        }
        provider.effectOverrides["goToWorkspace"] = { [weak self] in
            self?.workspacesPage().map { .push($0) }
        }
        for (id, make) in sources.actionPages {
            provider.effectOverrides[id] = { make().map { .push($0) } }
        }
        provider.effectOverrides["palette.terminalOpenDirectory"] = { [weak self] in
            self?.openInPage().map { .push($0) }
        }
        provider.effectOverrides["palette.toggleSetting"] = { [weak self] in
            self?.settingsPage().map { .push($0) }
        }
        provider.effectOverrides["renameTab"] = { [weak self] in
            guard let source = self?.sources.tabs, let tab = source.tabs.first(where: \.isSelected) else { return nil }
            return .textInput(PaletteTextInputSpec(
                id: "rename-tab:\(tab.id)",
                title: PaletteStrings.renameTab,
                placeholder: PaletteStrings.tabNamePlaceholder,
                initialText: tab.title,
                skipsUnchangedText: true,
                submitTitle: PaletteStrings.renameTo,
                submit: { source.renameTab(id: tab.id, to: $0) }
            ))
        }
        provider.effectOverrides["renameWorkspace"] = { [weak self] in
            guard let source = self?.sources.workspaces,
                  let workspace = source.workspaces.first(where: \.isSelected)
            else { return nil }
            return .textInput(PaletteTextInputSpec(
                id: "rename-workspace:\(workspace.id)",
                title: PaletteStrings.renameWorkspace,
                placeholder: PaletteStrings.workspaceNamePlaceholder,
                initialText: workspace.title,
                skipsUnchangedText: true,
                submitTitle: PaletteStrings.renameTo,
                submit: { source.renameWorkspace(id: workspace.id, to: $0) }
            ))
        }
        return provider
    }

    func page(for mode: PaletteMode) -> PalettePageSpec {
        switch mode {
        case .commands: return commandsPage()
        case .keyboardShortcuts: return page(forScope: PaletteScopeID.shortcuts, context: nil) ?? commandsPage()
        case .workspaces: return page(forScope: PaletteScopeID.workspaces, context: nil) ?? commandsPage()
        case .tabs: return tabsPage() ?? commandsPage()
        }
    }
}
