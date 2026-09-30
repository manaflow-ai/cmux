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
        return PalettePageSpec(
            id: "commands",
            title: PaletteStrings.commandsTitle,
            placeholder: PaletteStrings.searchPlaceholder,
            symbol: "command",
            providers: providers,
            showsRecent: true
        )
    }

    public func keyboardShortcutsPage() -> PalettePageSpec {
        PalettePageSpec(
            id: "shortcuts",
            title: PaletteStrings.shortcutsTitle,
            placeholder: PaletteStrings.shortcutsPlaceholder,
            symbol: "keyboard",
            providers: [KeyboardShortcutsPaletteProvider(registry: registry)]
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
        provider.targets = sources.targets
        provider.capturedTargets = capturedTargets
        provider.effectOverrides["palette.searchShortcuts"] = { [weak self] in
            self.map { .push($0.keyboardShortcutsPage()) }
        }
        provider.effectOverrides["goToWorkspace"] = { [weak self] in
            self?.workspacesPage().map { .push($0) }
        }
        provider.effectOverrides["palette.goToTab"] = { [weak self] in
            self?.tabsPage().map { .push($0) }
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
                submitTitle: PaletteStrings.renameTo,
                submit: { source.renameWorkspace(id: workspace.id, to: $0) }
            ))
        }
        return provider
    }

    func page(for mode: PaletteMode) -> PalettePageSpec {
        switch mode {
        case .commands: commandsPage()
        case .keyboardShortcuts: keyboardShortcutsPage()
        case .workspaces: workspacesPage() ?? commandsPage()
        case .tabs: tabsPage() ?? commandsPage()
        }
    }
}
