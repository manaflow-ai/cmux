import CmuxNextActions

extension PaletteModel {
    /// Asks every provider of a list page for items: immediate items land
    /// now (the first frame is never empty), async ones merge as they arrive.
    /// The hidden providers in `reading` read now, not after the frame.
    func load(_ state: PageState, reading: Set<String> = []) {
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
        state.providerTokens = []
        for provider in page.providers {
            if defersHidden, !provider.showsItemsForEmptyQuery, !reading.contains(provider.id) {
                state.providerItems[provider.id] = deferredStandIn(provider.id, page: page.id, state: state)
                deferred.append(provider)
                continue
            }
            // A provider whose empty query reads less than its search (the command page reads the actions its
            // root shows, not every catalog action): those rows now, the rest after the first frame.
            if defersHidden, !reading.contains(provider.id), let first = provider.firstFrameItems {
                state.providerItems[provider.id] = first
                deferred.append(provider)
                continue
            }
            // Followed from the read on: a change after it reads the rows again.
            follow(provider, of: state)
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
        state.liveReads += 1
        return Task { [weak self, weak state, weak counted = state] in
            defer { counted?.liveReads -= 1 }
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

    /// Keeps `provider`'s rows on `state` current while the page is open (a workspace created while Cmd-P shows):
    /// on each change of its source, its rows are read again, and the shown query is searched again with them.
    private func follow(_ provider: any PaletteProvider, of state: PageState) {
        let providerID = provider.id
        guard let token = provider.followChanges({ [weak self, weak state, weak provider] in
            guard let self, let state, let provider, self.pages[state.levelID] === state,
                  !self.deferredLoads.contains(where: { $0.state === state }) else { return }
            if let items = provider.immediateItems {
                self.apply(items, of: providerID, to: state)
            } else {
                state.pendingProviders.insert(providerID)
                state.tasks.append(self.loadTask(provider, into: state))
            }
        }) else { return }
        state.providerTokens.append(token)
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
                follow(provider, of: state)
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

    /// The rows a hidden provider shows until it reads again after the frame: the Recent rows the
    /// page's empty query last showed, each as `state` last read it. A reload of an open page (a
    /// setting's write landed) must not show the copy kept before a keep-open run read the row
    /// again: the empty query's rank keeps that copy only once it lands, so a write that landed
    /// first flashed the row's old On/Off back.
    func deferredStandIn(_ providerID: String, page pageID: String, state: PageState) -> [PaletteItem] {
        let shown = shownDeferredItems[pageID]?[providerID] ?? []
        guard !shown.isEmpty, let read = state.providerItems[providerID], !read.isEmpty else { return shown }
        let ids = Set(shown.map(\.id))
        var latest: [String: PaletteItem] = [:]
        for item in read where ids.contains(item.id) { latest[item.id] = item }
        return shown.map { latest[$0.id] ?? $0 }
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
                           keepsOrder: page.keepsSectionOrder, prefixFirst: page.ranksPrefixFirst,
                           names: page.filtersBySection ? state.filterSectionNames(page) : nil)
            let searcher = searcher
            // Not `page`: a search the next keystroke supersedes keeps running on the searcher,
            // and holding the page would keep its providers alive after the palette moved on.
            let queryItems = page.queryItems
            let noMatchItems = page.noMatchItems
            let trails = page.noMatchItemsTrailResults
            // The superseded search ranks nothing if it has not started (its result is stale anyway).
            searchTask?.cancel()
            searchTask = Task { [weak self, weak state] in
                let result = await searcher.search(
                    entries: request.entries, version: request.version,
                    query: request.query, generation: searchID, sectionOrders: request.orders,
                    frecency: request.frecency, now: request.now, showsRecent: request.recent,
                    keepsSectionOrder: request.keepsOrder, ranksPrefixFirst: request.prefixFirst,
                    sectionNames: request.names
                )
                guard let self, let state, result.generation == self.searchGeneration else { return }
                self.searchTask = nil
                let found = self.withScopeTokenSuggestions(Self.leading(queryItems?(request.query), state.resolve(result.sections)),
                                                           query: request.query, state: state)
                self.deliver(Self.orNoMatch(found, noMatchItems, trails: trails, query: request.query, state: state), to: state, generation: generation)
                self.closeIfPending()
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
            self.closeIfPending()
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

    /// `sections`, or the page's no-match rows first when the typed query found no row and no provider
    /// is still loading (a loading provider may yet match); with `trails`, after the rows it found.
    static func orNoMatch(_ sections: [PaletteResultSection], _ noMatch: (@MainActor (String) -> [PaletteItem])?, trails: Bool,
                          query: String, state: PageState) -> [PaletteResultSection] {
        guard let noMatch, state.pendingProviders.isEmpty else { return sections }
        guard sections.contains(where: { !$0.rows.isEmpty }) else { return leading(noMatch(query), sections) }
        guard trails else { return sections }
        let items = noMatch(query)
        guard let first = items.first else { return sections }
        return sections + [PaletteResultSection(section: first.section, rows: items.map { PaletteRow(item: $0, highlights: [], score: 0) })]
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
        // The v2 scope bar's typed tokens keep only the rows they name (`PaletteScopeFilter`).
        let ranked = scopeTokenFiltered(sections, state: state)
        state.rankedSections = ranked
        state.rankedGeneration = generation
        state.rankedProvisional = provisional
        state.rankedComplete = complete
        let joined = Self.joined(ranked, state: state)
        state.deliveredAnswerFingerprint = Self.answerFingerprint(state)
        let held = joined.held
        // The v2 look: the rows under its four group headers, the top match first (`PaletteV2Grouping`).
        let groups = groupsRows(state)
        let sections = groups ? PaletteV2Grouping.regroup(joined.shown) : joined.shown
        var selectable = joined.selectable
        if groups {
            // The same cut as `joined`: navigation never selects a stand-in row, and every row it may select shows.
            let standIns = joined.shown.count != joined.selectable.count
            selectable = standIns ? PaletteV2Grouping.keeping(Set(joined.selectable.lazy.flatMap(\.rows).map(\.id)), of: sections) : sections
        }
        state.lastSections = sections
        state.awaitsRank = provisional
        if !provisional { recordShownDeferredItems(sections, on: state) }
        if shownLevelID == state.levelID {
            queryFrames.delivered(final: complete && !provisional, answerRows: state.currentAnswers.reduce(0) { $0 + $1.rows.count })
            display(sections)
        }
        // The rail's choice narrows what navigation walks as it narrows the list (`display`).
        if railFilter != nil, railLevelID == state.levelID { selectable = PaletteV2Grouping.filter(selectable, to: railFilter) }
        // Grouped, every new result set selects its first row: the top match (a page's own empty-query row index
        // names a row of the ungrouped order).
        send(.results(levelID: state.levelID, generation: generation, rows: navRows(selectable), replace: true,
                      isFinal: complete && !provisional && !held && state.pendingProviders.isEmpty,
                      emptyQuerySelection: groups ? 0 : state.emptyQuerySelection, provisional: provisional || held))
    }

    /// Whether `state` shows its rows under the v2 look's groups: only the full palette and Search, never an
    /// argument picker, a text step or a setting's values.
    func groupsRows(_ state: PageState) -> Bool {
        guard experiments.look.isOn, case .list(let page) = state.kind else { return false }
        return page.scopeID == .root || page.scopeID == PaletteScopeID.search
    }

    /// The rail's click or key (`PaletteV2Look.rail`): narrows the shown page's list to `group` (All when nil),
    /// with its first row selected. Counts stay those of the whole query.
    public func chooseRail(_ group: PaletteV2Group?) {
        guard experiments.look.showsRail, let state = current, state.levelID == shownLevelID, groupsRows(state) else { return }
        guard group == nil || railEntries.contains(where: { $0.group == group }) else { return }
        guard railFilter != group || railLevelID != state.levelID else { return }
        railFilter = group
        railLevelID = state.levelID
        if let ranked = state.rankedSections, state.rankedGeneration == state.generation {
            deliver(ranked, to: state, generation: state.generation, provisional: state.rankedProvisional,
                    complete: state.rankedComplete)
        } else {
            display(state.lastSections ?? [])
        }
        if let first = rows.first {
            send(.select(first.id))
            scrollRequest += 1
        }
    }

    /// ⌥↑ / ⌥↓ on the rail: the entry `delta` steps from the chosen one (no wrap). False when no rail shows.
    @discardableResult
    public func moveRail(by delta: Int) -> Bool {
        guard experiments.look.showsRail, actionsMenu == nil, !railEntries.isEmpty else { return false }
        let index = railEntries.firstIndex { $0.group == railFilter } ?? 0
        let next = min(max(index + delta, 0), railEntries.count - 1)
        if next != index { chooseRail(railEntries[next].group) }
        return true
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
        let newSections = railed(newSections)
        sections = notice.map { Self.applying($0, to: newSections) } ?? newSections
        resultsVersion += 1
        let rows = self.rows
        if let menu = actionsMenu, !rows.contains(where: { $0.id == menu.itemID }) {
            actionsMenu = nil
        }
    }

    /// The rail of the shown page's grouped rows (`railEntries`, counts of the whole query) and those rows
    /// narrowed to its choice. Another page starts at All; a choice whose group the query no longer has goes back
    /// to All.
    private func railed(_ grouped: [PaletteResultSection]) -> [PaletteResultSection] {
        if railLevelID != shownLevelID {
            railLevelID = shownLevelID
            if railFilter != nil { railFilter = nil }
        }
        guard experiments.look.showsRail, let state = shownLevelID.flatMap({ pages[$0] }), groupsRows(state) else {
            if !railEntries.isEmpty { railEntries = [] }
            if railFilter != nil { railFilter = nil }
            return grouped
        }
        let entries = PaletteV2Grouping.railEntries(grouped)
        if entries != railEntries { railEntries = entries }
        if let filter = railFilter, !entries.contains(where: { $0.group == filter }) { railFilter = nil }
        return PaletteV2Grouping.filter(grouped, to: railFilter)
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
