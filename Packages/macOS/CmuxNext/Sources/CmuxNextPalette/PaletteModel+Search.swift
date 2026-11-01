import CmuxNextActions

extension PaletteModel {
    /// Asks every provider of a list page for items: immediate items land
    /// now (the first frame is never empty), async ones merge as they arrive.
    func load(_ state: PageState) {
        state.needsLoad = false
        guard case .list(let page) = state.kind else { return }
        state.cancel()
        deferredLoads.removeAll { $0.state === state }
        var pending = Set<String>()
        // A filtering page's empty query lists none of a hidden provider's rows (the command
        // page's workspaces and tabs), only the few it showed as Recent: those stand in, and the
        // provider reads its source after the first frame (Cmd-Shift-P with thousands of tabs).
        let defersHidden = page.filtersByQuery && state.query.allSatisfy(\.isWhitespace)
        var deferred: [any PaletteProvider] = []
        for provider in page.providers {
            if defersHidden, !provider.showsItemsForEmptyQuery {
                state.providerItems[provider.id] = shownDeferredItems[page.id]?[provider.id] ?? []
                deferred.append(provider)
                continue
            }
            // Read once: most providers build their rows in `immediateItems` (the command page's
            // registry builds a row per catalog action, Go to Workspace one per workspace).
            let immediate = provider.immediateItems
            if let immediate {
                state.providerItems[provider.id] = immediate
            }
            if immediate == nil || provider.refreshesOnOpen {
                pending.insert(provider.id)
            }
        }
        state.pendingProviders = pending
        state.rebuild()
        if state === current { isLoading = !pending.isEmpty }
        for provider in page.providers where pending.contains(provider.id) {
            state.tasks.append(loadTask(provider, into: state))
        }
        if !deferred.isEmpty {
            let scheduled = !deferredLoads.isEmpty
            deferredLoads.append(PaletteDeferredLoad(state: state, providers: deferred))
            if !scheduled { afterFrame { [weak self] in self?.flushDeferredLoads() } }
        }
    }

    /// Reads `provider` into `state`: its items once, or each list of its updates as it comes
    /// (``PaletteProvider/itemUpdates()``). Same generation: the rows update, the selection stays.
    private func loadTask(_ provider: any PaletteProvider, into state: PageState) -> Task<Void, Never> {
        let providerID = provider.id
        return Task { [weak self, weak state] in
            if let updates = provider.itemUpdates() {
                var any = false
                for await items in updates {
                    guard !Task.isCancelled, let self, let state else { return }
                    any = true
                    self.apply(items, of: providerID, to: state)
                }
                // A stream that ended with no list leaves the provider's rows as they were, not loading.
                guard !any, !Task.isCancelled, let self, let state else { return }
                self.apply(state.providerItems[providerID] ?? [], of: providerID, to: state)
                return
            }
            let items = await provider.items()
            guard !Task.isCancelled, let self, let state else { return }
            self.apply(items, of: providerID, to: state)
        }
    }

    private func apply(_ items: [PaletteItem], of providerID: String, to state: PageState) {
        state.providerItems[providerID] = items
        state.pendingProviders.remove(providerID)
        state.rebuild()
        if state === current {
            isLoading = !state.pendingProviders.isEmpty
            search(state)
        }
    }

    /// Builds the providers opens left for after their first frame, into
    /// pages still on the stack, and searches the shown page again with them.
    func flushDeferredLoads() {
        guard !deferredLoads.isEmpty else { return }
        let loads = deferredLoads
        deferredLoads = []
        for load in loads where pages[load.state.levelID] === load.state {
            let state = load.state
            for provider in load.providers {
                if let items = provider.immediateItems {
                    state.providerItems[provider.id] = items
                    if !provider.refreshesOnOpen { continue }
                }
                state.pendingProviders.insert(provider.id)
                state.tasks.append(loadTask(provider, into: state))
            }
            state.rebuild()
            if state === current {
                isLoading = !state.pendingProviders.isEmpty
                search(state)
            }
        }
    }

    /// Keeps the deferred providers' items that `sections` show on `state`'s
    /// empty query (Recent rows), for the next open's first frame.
    func recordShownDeferredItems(_ sections: [PaletteResultSection], on state: PageState) {
        guard case .list(let page) = state.kind, page.filtersByQuery, state.query.allSatisfy(\.isWhitespace),
              !deferredLoads.contains(where: { $0.state === state }) else { return }
        let hidden = page.providers.filter { !$0.showsItemsForEmptyQuery }
        guard !hidden.isEmpty else { return }
        let shown = Set(sections.lazy.flatMap(\.rows).map(\.id))
        var kept: [String: [PaletteItem]] = [:]
        for provider in hidden {
            let items = (state.providerItems[provider.id] ?? []).filter { shown.contains($0.id) }
            if !items.isEmpty { kept[provider.id] = items }
        }
        shownDeferredItems[page.id] = kept
    }

    /// Ranks the page's rows for its query and generation on the searcher,
    /// off the main actor. An empty query shows its last rank or its
    /// unranked rows at once (`searchEmpty`); for a real query the rows on
    /// screen stay until its result lands.
    func search(_ state: PageState) { // perf-hot: 4ms palette-key (every query key; ranking stays off main)
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
            followSources(state, page: page)
            if let queryResults = page.queryResults {
                searchQueryResults(state, results: queryResults, generation: generation)
                return
            }
            askContributions(state, page: page)
            // A typed query searches every row: the open's deferred providers load first.
            if !state.query.allSatisfy(\.isWhitespace), deferredLoads.contains(where: { $0.state === state }) {
                flushDeferredLoads()
                // The flush searched the shown page with every row.
                if state === current { return }
            }
            searchGeneration += 1
            let searchID = searchGeneration
            if state.query.allSatisfy(\.isWhitespace) || !page.filtersByQuery {
                searchEmpty(state, page: page, generation: generation, searchID: searchID)
                return
            }
            let request = (query: state.query, entries: state.entries, version: state.version,
                           orders: state.sectionOrders, frecency: frecency, now: now(), recent: page.showsRecent,
                           keepsOrder: page.keepsSectionOrder, prefixFirst: page.ranksPrefixFirst)
            let searcher = searcher
            // Not `page`: a search the next keystroke supersedes keeps running on the searcher,
            // and holding the page would keep its providers alive after the palette moved on.
            let queryItems = page.queryItems
            // The superseded search ranks nothing if it has not started (its result is stale anyway).
            searchTask?.cancel()
            searchTask = Task { [weak self, weak state] in
                let result = await searcher.search(
                    entries: request.entries, version: request.version,
                    query: request.query, generation: searchID, sectionOrders: request.orders,
                    frecency: request.frecency, now: request.now, showsRecent: request.recent,
                    keepsSectionOrder: request.keepsOrder, ranksPrefixFirst: request.prefixFirst
                )
                guard let self, let state, result.generation == self.searchGeneration else { return }
                self.searchTask = nil
                self.deliver(Self.leading(queryItems?(request.query), state.resolve(result.sections)), to: state,
                             generation: generation)
                if self.pendingClose {
                    self.pendingClose = false
                    self.handle(.closeItem)
                }
            }
        }
    }

    /// A page that finds its own rows for the query (`queryResults`): the
    /// newest query's stream replaces the one before, and each of its answers
    /// lands with the typed words highlighted in their titles. The rows are
    /// final (Return no longer waits, the spinner stops) when the stream ends.
    func searchQueryResults(_ state: PageState, results: @escaping @MainActor (String) -> AsyncStream<[PaletteItem]>,
                            generation: Int) {
        searchGeneration += 1
        let searchID = searchGeneration
        let query = state.query
        searchTask?.cancel()
        // The search field's spinner while the page looks (Search All Windows reads every terminal first).
        state.answeringSearch = searchID
        if state === current { isLoading = true }
        let answers = results(query)
        searchTask = Task { [weak self, weak state] in
            // However this search ends, it no longer answers the page (a newer one may).
            defer { if state?.answeringSearch == searchID { state?.answeringSearch = nil } }
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            var last: [PaletteResultSection]?
            for await items in answers {
                guard !Task.isCancelled, let self, let state, searchID == self.searchGeneration else { return }
                let sections = Self.querySections(items, words: words)
                last = sections
                self.deliver(sections, to: state, generation: generation, complete: false)
            }
            guard !Task.isCancelled, let self, let state, searchID == self.searchGeneration else { return }
            self.searchTask = nil
            state.answeringSearch = nil
            if state === self.current { self.isLoading = false }
            self.deliver(last ?? [], to: state, generation: generation)
            if self.pendingClose {
                self.pendingClose = false
                self.handle(.closeItem)
            }
        }
    }

    /// One block per section, in the order the sections first appear (linear: a search
    /// can return thousands of terminal lines, and copying a section per row was quadratic).
    static func querySections(_ items: [PaletteItem], words: [String]) -> [PaletteResultSection] {
        var order: [PaletteSection] = []
        var rowsBySection: [PaletteSection: [PaletteRow]] = [:]
        for item in items {
            let row = PaletteRow(item: item, highlights: wordHighlights(in: item.title, words: words), score: 0)
            if rowsBySection[item.section] == nil { order.append(item.section) }
            rowsBySection[item.section, default: []].append(row)
        }
        return order.map { PaletteResultSection(section: $0, rows: rowsBySection[$0] ?? []) }
    }

    /// Scalar offsets of every case-insensitive occurrence of `words` in `title`.
    static func wordHighlights(in title: String, words: [String]) -> [Int] {
        guard !words.isEmpty else { return [] }
        let scalars = Array(title.lowercased().unicodeScalars)
        // Lowercasing can change the scalar count (rare); offsets would point past the title then.
        guard scalars.count == title.unicodeScalars.count else { return [] }
        var marked = Set<Int>()
        for word in words {
            let needle = Array(word.lowercased().unicodeScalars)
            guard !needle.isEmpty, needle.count <= scalars.count else { continue }
            var start = 0
            while start + needle.count <= scalars.count {
                if scalars[start..<start + needle.count].elementsEqual(needle) {
                    marked.formUnion(start..<start + needle.count)
                    start += needle.count
                } else {
                    start += 1
                }
            }
        }
        return marked.sorted()
    }

    /// `sections` after the page's rows made from the query, if any.
    static func leading(_ items: [PaletteItem]?, _ sections: [PaletteResultSection]) -> [PaletteResultSection] {
        guard let items, !items.isEmpty else { return sections }
        let rows = items.map { PaletteRow(item: $0, highlights: [], score: 0) }
        return [PaletteResultSection(section: items[0].section, rows: rows)] + sections
    }

    /// A page's rows for `generation`: cached on the page, shown when the
    /// page is on screen, and handed to the reducer, which takes them only
    /// for the level's current generation and keeps or moves the selection.
    /// `provisional` rows stand in until the ranked rows of the same
    /// generation land (`PaletteNavEvent.results`).
    /// `complete` false: more rows of the same generation follow (a `queryResults` stream reads on).
    func deliver(_ sections: [PaletteResultSection], to state: PageState, generation: Int, provisional: Bool = false,
                 complete: Bool = true) {
        guard pages[state.levelID] === state, state.generation == generation else { return }
        // The contributed answers join the ranked rows (`PaletteContributedAnswers`): an older query's answer
        // shows only as a stand-in that navigation never selects, and a held query's rows are not final.
        state.rankedSections = sections
        state.rankedGeneration = generation
        state.rankedProvisional = provisional
        state.rankedComplete = complete
        let joined = Self.joined(sections, state: state)
        state.deliveredAnswerFingerprint = Self.answerFingerprint(state)
        let held = joined.held
        let sections = joined.shown
        state.lastSections = sections
        state.awaitsRank = provisional
        if !provisional { recordShownDeferredItems(sections, on: state) }
        if shownLevelID == state.levelID {
            queryFrames.delivered(final: complete && !provisional, answerRows: state.currentAnswers.reduce(0) { $0 + $1.rows.count })
            display(sections)
        }
        send(.results(levelID: state.levelID, generation: generation, rows: navRows(joined.selectable), replace: true,
                      isFinal: complete && !provisional && !held && state.pendingProviders.isEmpty,
                      emptyQuerySelection: state.emptyQuerySelection, provisional: provisional || held))
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
