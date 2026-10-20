extension PaletteController {
    /// Search (scope `search`, the sidebar's Search button;
    /// plans/cmux-next/sidebar-search.md): the providers Go to Workspace and
    /// the root already have (workspaces; groups, panes and tabs; recent
    /// folders; settings; every command; apps), plus the App's contributed
    /// pages (history, agent chats), ranked by the palette's one off-main
    /// searcher. Rows keep one section per kind, so a query reads as blocks
    /// of Workspaces, Tabs, History, Settings and Commands. The empty query
    /// shows Recent and the workspaces (Cmd-P's old first results).
    func searchPage() -> PalettePageSpec {
        var providers: [any PaletteProvider] = []
        if let source = sources.workspaces {
            // Before typing, the workspaces show, as Go to Workspace (the old Cmd-P) showed them.
            providers.append(WorkspacePaletteProvider(source: source, showsItemsForEmptyQuery: true))
        }
        // The navigation source lists every tab (with groups and panes); the plain tab list is the fallback.
        if let source = sources.navigation {
            providers.append(NavigationPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        } else if let source = sources.tabs {
            providers.append(TabPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.recentDirectories {
            providers.append(RecentDirectoriesPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        for contribution in sources.searchContributions {
            guard let page = contribution.page() else { continue }
            let section = PaletteSection(id: "search.\(contribution.id)", title: contribution.title, order: contribution.order)
            for provider in page.providers {
                providers.append(PaletteSearchSectionedProvider(provider, id: "search.\(contribution.id).\(provider.id)", section: section))
            }
        }
        if let source = sources.settings {
            providers.append(SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        // The catalog's per-category sections read as one Commands block here.
        let commands = PaletteSection(id: "search.commands", title: PaletteStrings.commandsTitle, order: 60)
        providers.append(PaletteSearchSectionedProvider(makeRegistryProvider(), section: commands, replacesSections: true))
        providers += sources.extraProviders.map { PaletteSearchSectionedProvider($0, section: nil) }
        var page = PalettePageSpec(
            id: "search",
            title: PaletteStrings.searchEverythingTitle,
            placeholder: PaletteStrings.searchEverythingPlaceholder,
            symbol: "magnifyingglass",
            providers: providers,
            showsRecent: true,
            scope: PaletteScopeID.search
        )
        page.queryItems = goToRows()
        return previewingActions(page)
    }
}
