import CmuxNextActions

extension PaletteModel {
    /// Asks every provider of a list page for items: immediate items land
    /// now (the first frame is never empty), async ones merge as they arrive.
    func load(_ state: PageState) {
        state.needsLoad = false
        guard case .list(let page) = state.kind else { return }
        state.cancel()
        var pending = Set<String>()
        for provider in page.providers {
            if let items = provider.immediateItems {
                state.providerItems[provider.id] = items
            } else {
                pending.insert(provider.id)
            }
        }
        state.pendingProviders = pending
        state.rebuild()
        if state === current { isLoading = !pending.isEmpty }
        for provider in page.providers where pending.contains(provider.id) {
            let providerID = provider.id
            state.tasks.append(Task { [weak self, weak state] in
                let items = await provider.items()
                guard !Task.isCancelled, let self, let state else { return }
                state.providerItems[providerID] = items
                state.pendingProviders.remove(providerID)
                state.rebuild()
                if state === self.current {
                    self.isLoading = !state.pendingProviders.isEmpty
                    // Same generation: the rows update, the selection stays.
                    self.search(state)
                }
            })
        }
    }

    /// Ranks the page's rows for its query and generation. An empty query
    /// ranks on the main actor (no matching, just grouping); a real query
    /// goes to the searcher and the rows on screen stay until its result
    /// lands.
    func search(_ state: PageState) {
        let generation = state.generation
        switch state.kind {
        case .textInput(let spec):
            searchGeneration += 1
            searchTask = nil
            let text = state.query
            let item = PaletteItem(
                id: "submit",
                title: spec.submitTitle(text),
                symbol: spec.symbol,
                keycaps: ["↩"],
                isEnabled: spec.isValid(text),
                primary: PaletteCommand(
                    id: "submit",
                    title: PaletteStrings.submit,
                    symbol: "return",
                    effect: spec.skipsUnchangedText && !spec.initialText.isEmpty && text == spec.initialText
                        ? .perform({}) : spec.next?(text) ?? .perform { spec.submit(text) }
                ),
                frecencyKey: nil
            )
            deliver([PaletteResultSection(section: .results, rows: [PaletteRow(item: item, highlights: [], score: 0)])],
                    to: state, generation: generation)
        case .list(let page):
            searchGeneration += 1
            let searchID = searchGeneration
            if FuzzyQuery(state.query).isEmpty {
                searchTask = nil
                let ranked = PaletteRanker.rankEmpty(
                    entries: state.entries,
                    sectionOrders: state.sectionOrders,
                    frecency: frecency,
                    now: now(),
                    showsRecent: page.showsRecent
                )
                deliver(state.resolve(ranked), to: state, generation: generation)
                return
            }
            let request = (query: state.query, entries: state.entries, version: state.version,
                           orders: state.sectionOrders, frecency: frecency, now: now(), recent: page.showsRecent,
                           keepsOrder: page.keepsSectionOrder)
            let searcher = searcher
            searchTask = Task { [weak self, weak state] in
                await searcher.install(entries: request.entries, version: request.version)
                let result = await searcher.search(
                    query: request.query, generation: searchID, sectionOrders: request.orders,
                    frecency: request.frecency, now: request.now, showsRecent: request.recent,
                    keepsSectionOrder: request.keepsOrder
                )
                guard let self, let state, result.generation == self.searchGeneration else { return }
                self.searchTask = nil
                self.deliver(state.resolve(result.sections), to: state, generation: generation)
                if self.pendingClose {
                    self.pendingClose = false
                    self.handle(.closeItem)
                }
            }
        }
    }

    /// A page's rows for `generation`: cached on the page, shown when the
    /// page is on screen, and handed to the reducer, which takes them only
    /// for the level's current generation and keeps or moves the selection.
    func deliver(_ sections: [PaletteResultSection], to state: PageState, generation: Int) {
        guard pages[state.levelID] === state, state.generation == generation else { return }
        state.lastSections = sections
        if shownLevelID == state.levelID { display(sections) }
        send(.results(levelID: state.levelID, generation: generation, rows: navRows(sections), replace: true,
                      isFinal: state.pendingProviders.isEmpty, emptyQuerySelection: state.emptyQuerySelection))
    }

    /// What navigation needs from the rows.
    func navRows(_ sections: [PaletteResultSection]) -> [PaletteNavRow] {
        sections.flatMap(\.rows).map { row in
            let item = row.item
            let drill = item.drills ?? (itemActionsAsScope && !item.secondary.isEmpty ? PaletteScopeID.actionsScope : nil)
            return PaletteNavRow(id: item.id, enters: item.enters, drills: drill, isEnabled: item.isEnabled)
        }
    }

    /// Puts `newSections` on screen (with the notice, if any). The
    /// selection is the reducer's.
    func display(_ newSections: [PaletteResultSection]) {
        sections = notice.map { Self.applying($0, to: newSections) } ?? newSections
        resultsVersion += 1
        let rows = self.rows
        if let menu = actionsMenu, !rows.contains(where: { $0.id == menu.itemID }) {
            actionsMenu = nil
        }
    }

    /// Re-shows the rows on screen (after a notice changed).
    func publish(_ newSections: [PaletteResultSection], resetSelection: Bool) {
        display(current?.lastSections ?? newSections)
    }

    /// The notice replaces its row's subtitle.
    static func applying(_ notice: PaletteNotice, to sections: [PaletteResultSection]) -> [PaletteResultSection] {
        sections.map { section in
            PaletteResultSection(section: section.section, rows: section.rows.map { row in
                guard row.id == notice.rowID else { return row }
                var item = row.item
                item.subtitle = notice.text
                return PaletteRow(item: item, highlights: row.highlights, score: row.score)
            })
        }
    }
}
