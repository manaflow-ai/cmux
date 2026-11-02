extension PaletteController {
    /// Search (scope `search`, the sidebar's Search button;
    /// plans/cmux-next/sidebar-search.md): the providers Go to Workspace and
    /// the root already have (workspaces; groups, panes and tabs; recent
    /// folders; settings; every command; apps), plus the App's contributed
    /// pages (history, agent chats), ranked by the palette's one off-main
    /// searcher. Rows keep one section per kind, so a query reads as blocks
    /// of Workspaces, Tabs, History, Settings and Commands. The empty query
    /// shows Recent and the workspaces. Cmd-Shift-A opens it; Cmd-P is `workspacesPage`.
    func searchPage() -> PalettePageSpec {
        var providers: [any PaletteProvider] = []
        if let source = sources.workspaces {
            // Before typing, the workspaces show, as on Cmd-P.
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
        let contributed = contributed(sources.searchContributions)
        providers += contributed.providers
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
        page.contributedAnswers = contributed.answers
        return previewingActions(page)
    }

    /// Chats & agents (scope `chats`): the contributed pages that list chats and agent sessions,
    /// nothing else.
    func chatsPage() -> PalettePageSpec {
        let contributed = contributed(sources.searchContributions.filter(\.searchesChats), showsItemsForEmptyQuery: true)
        var page = PalettePageSpec(
            id: "chats",
            title: PaletteStrings.chatsAndAgentsTitle,
            placeholder: PaletteStrings.chatsAndAgentsPlaceholder,
            symbol: "bubble.left.and.bubble.right",
            providers: contributed.providers,
            showsRecent: true,
            scope: PaletteScopeID.chats
        )
        page.contributedAnswers = contributed.answers
        return page
    }

    /// Each contribution's rows under the contribution's section unless they carry one: its providers'
    /// rows, ranked with the page's own, or, for a page that answers its own queries
    /// (`PalettePageSpec.queryResults`, the agent chats page asks acpmux), its answer to each query.
    private func contributed(_ contributions: [PaletteSearchContribution], showsItemsForEmptyQuery: Bool = false)
        -> (providers: [any PaletteProvider], answers: [PaletteContributedAnswers]) {
        var providers: [any PaletteProvider] = []
        var answers: [PaletteContributedAnswers] = []
        for contribution in contributions {
            guard let page = contribution.page() else { continue }
            let section = PaletteSection(id: "search.\(contribution.id)", title: contribution.title, order: contribution.order)
            // Such a page ignores its providers too when it shows on its own (`PaletteModel.search`).
            if let results = page.queryResults {
                // In the Chats & agents scope the chats are the main content (`leads`); in Search one block of many.
                answers.append(PaletteContributedAnswers(section: section, leads: showsItemsForEmptyQuery,
                                                         results: results, close: page.onCancel, moreRow: page.moreRow,
                                                         onSourceChange: page.onSourceChange))
                continue
            }
            for provider in page.providers {
                providers.append(PaletteSearchSectionedProvider(provider, id: "search.\(contribution.id).\(provider.id)", section: section,
                                                               showsItemsForEmptyQuery: showsItemsForEmptyQuery))
            }
        }
        return (providers, answers)
    }
}
