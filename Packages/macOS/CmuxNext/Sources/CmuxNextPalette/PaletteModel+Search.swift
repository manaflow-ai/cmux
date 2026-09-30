import CmuxNextActions

extension PaletteModel {
    /// Asks every provider of a list page for items: immediate items land
    /// now (the first frame is never empty), async ones merge as they arrive.
    func load(_ state: PageState) {
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
                    self.refreshResults(resetSelection: false)
                }
            })
        }
    }

    /// Recomputes rows for the current page. An empty query ranks on the
    /// main actor (no matching, just grouping); a real query goes to the
    /// searcher and the rows on screen stay until its result lands.
    func refreshResults(resetSelection: Bool) {
        guard let state = current else {
            publish([], resetSelection: true)
            return
        }
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
                    effect: spec.next?(text) ?? .perform { spec.submit(text) }
                ),
                frecencyKey: nil
            )
            publish([PaletteResultSection(section: .results, rows: [PaletteRow(item: item, highlights: [], score: 0)])],
                    resetSelection: true)
        case .list(let page):
            searchGeneration += 1
            let generation = searchGeneration
            if FuzzyQuery(state.query).isEmpty {
                searchTask = nil
                let ranked = PaletteRanker.rankEmpty(
                    entries: state.entries,
                    sectionOrders: state.sectionOrders,
                    frecency: frecency,
                    now: now(),
                    showsRecent: page.showsRecent
                )
                publish(state.resolve(ranked), resetSelection: resetSelection)
                return
            }
            let request = (query: state.query, entries: state.entries, version: state.version,
                           orders: state.sectionOrders, frecency: frecency, now: now(), recent: page.showsRecent)
            let searcher = searcher
            searchTask = Task { [weak self, weak state] in
                await searcher.install(entries: request.entries, version: request.version)
                let result = await searcher.search(
                    query: request.query, generation: generation, sectionOrders: request.orders,
                    frecency: request.frecency, now: request.now, showsRecent: request.recent
                )
                guard let self, let state, result.generation == self.searchGeneration, state === self.current else { return }
                self.searchTask = nil
                self.publish(state.resolve(result.sections), resetSelection: resetSelection)
                if let submit = self.pendingSubmit {
                    self.pendingSubmit = nil
                    self.handle(submit)
                }
            }
        }
    }

    func publish(_ newSections: [PaletteResultSection], resetSelection: Bool) {
        sections = notice.map { Self.applying($0, to: newSections) } ?? newSections
        resultsVersion += 1
        let rows = self.rows
        if resetSelection || selectedRowID == nil || !rows.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = rows.first?.id
            scrollRequest += 1
        }
        if let menu = actionsMenu, !rows.contains(where: { $0.id == menu.itemID }) {
            actionsMenu = nil
        }
        current?.selectedRowID = selectedRowID
        current?.lastSections = newSections
        applyRestoredSelection()
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
