/// What an empty-query rank ranks: a page's rows as the searcher takes them,
/// with the stable id and section of every entry, so the result maps back to
/// rows of a later snapshot of the same page by id, never by index.
struct PaletteEmptyRankInput: Sendable {
    let pageID: String
    let entries: [PaletteSearchEntry]
    let version: Int
    /// The id of `entries[i]`'s item.
    let ids: [String]
    /// The page's section table (`PaletteSearchEntry.sectionIndex` indexes it).
    let sections: [PaletteSection]
    let showsRecent: Bool

    init(page: PalettePageSpec, state: PageState) {
        pageID = page.id
        entries = state.entries
        version = state.version
        ids = state.items.map(\.id)
        sections = state.sections
        showsRecent = page.showsRecent
    }

    var sectionOrders: [Int] { sections.map(\.order) }
}

/// The last empty-query rank of a page, rows by stable id. The model shows it
/// at once when the page opens (or its rows change) while the next rank runs
/// off the main actor; that rank replaces it when it lands.
struct PaletteEmptyRank: Sendable {
    struct Row: Sendable {
        let id: String
        let score: Int
        let highlights: [Int]
    }

    struct Section: Sendable {
        let section: PaletteSection
        let rows: [Row]
    }

    /// What was ranked: ranked again when usage changes (`prewarmEmptyRanks`).
    let input: PaletteEmptyRankInput
    /// `PaletteModel.frecencyRevision` the rank used.
    let frecencyRevision: Int
    let sections: [Section]

    init(input: PaletteEmptyRankInput, frecencyRevision: Int, ranked: [PaletteRankedSection]) {
        self.input = input
        self.frecencyRevision = frecencyRevision
        sections = ranked.map { section in
            Section(
                section: section.sectionIndex.flatMap { input.sections.indices.contains($0) ? input.sections[$0] : nil } ?? .recent,
                rows: section.rows.compactMap { row in
                    guard input.ids.indices.contains(row.index) else { return nil }
                    return Row(id: input.ids[row.index], score: row.score, highlights: row.highlights)
                }
            )
        }
    }

    /// The rank is the one a fresh rank of `state` would give now: same rows, same usage.
    func isExact(for state: PageState, frecencyRevision: Int) -> Bool {
        input.version == state.version && self.frecencyRevision == frecencyRevision
    }

    /// The ranked rows that `state` still has, by id, with its current items.
    /// Rows the page no longer has are dropped; rows it gained wait for the next rank.
    func resolve(on state: PageState) -> [PaletteResultSection] {
        var items: [String: PaletteItem] = [:]
        items.reserveCapacity(state.items.count)
        for item in state.items { items[item.id] = item }
        return sections.compactMap { section in
            let rows = section.rows.compactMap { row in
                items[row.id].map { PaletteRow(item: $0, highlights: row.highlights, score: row.score) }
            }
            return rows.isEmpty ? nil : PaletteResultSection(section: section.section, rows: rows)
        }
    }
}

/// An empty-query rank in flight for one page.
struct PaletteEmptyRankRequest {
    let token: Int
    /// The snapshot and usage it ranks: a request for the same pair reuses it.
    let version: Int
    let frecencyRevision: Int
    let task: Task<PaletteEmptyRank?, Never>
}

extension PaletteModel {
    /// How many pages keep their last empty-query rank.
    static let emptyRankPageLimit = 4

    /// The empty query of a list page. Its rank runs off the main actor; until it lands the page
    /// shows its last rank (by row id) or, on the first open, its rows unranked in section order,
    /// so the first frame is never empty. The ranked rows replace them for the same generation.
    func searchEmpty(_ state: PageState, page: PalettePageSpec, generation: Int, searchID: Int) {
        // The superseded search's rows would be stale.
        searchTask?.cancel()
        searchTask = nil
        let query = state.query
        let queryItems = page.queryItems
        let cached = emptyRanks[page.id]
        if let cached, cached.isExact(for: state, frecencyRevision: frecencyRevision) {
            deliver(Self.leading(queryItems?(query), cached.resolve(on: state)), to: state, generation: generation)
            return
        }
        let standIn = cached.map { $0.resolve(on: state) }.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unranked(state)
        deliver(Self.leading(queryItems?(query), standIn), to: state, generation: generation, provisional: true)
        let rank = requestEmptyRank(PaletteEmptyRankInput(page: page, state: state))
        searchTask = Task { [weak self, weak state] in
            let ranked = await rank.value
            guard let self, let state, searchID == self.searchGeneration else { return }
            self.searchTask = nil
            // Nil only when a newer request superseded this one; the rows stand final unranked
            // rather than wait on a rank no one delivers.
            let sections = ranked?.resolve(on: state) ?? Self.unranked(state)
            self.deliver(Self.leading(queryItems?(query), sections), to: state, generation: generation)
            if self.pendingClose {
                self.pendingClose = false
                self.handle(.closeItem)
            }
        }
    }

    /// Ranks `input`'s empty query on the searcher and keeps the result for the page. A newer
    /// request for the same page supersedes this one (it ranks nothing if it has not started, and
    /// its result never replaces a newer one). A typed search does not cancel it: the next open
    /// still finds the rank.
    func requestEmptyRank(_ input: PaletteEmptyRankInput) -> Task<PaletteEmptyRank?, Never> {
        let pageID = input.pageID
        let revision = frecencyRevision
        if let running = emptyRankRequests[pageID], running.version == input.version, running.frecencyRevision == revision {
            // The same rows and usage (typing on a page that does not filter): its rank is this one.
            return running.task
        }
        emptyRankRequestCounter += 1
        let token = emptyRankRequestCounter
        emptyRankRequests[pageID]?.task.cancel()
        let frecency = frecency
        let now = now()
        let searcher = searcher
        let task = Task { [weak self] () -> PaletteEmptyRank? in
            guard let ranked = await searcher.rankEmpty(entries: input.entries, version: input.version,
                                                        sectionOrders: input.sectionOrders, frecency: frecency,
                                                        now: now, showsRecent: input.showsRecent) else { return nil }
            guard let self, self.emptyRankRequests[pageID]?.token == token else { return nil }
            self.emptyRankRequests[pageID] = nil
            let rank = PaletteEmptyRank(input: input, frecencyRevision: revision, ranked: ranked)
            self.storeEmptyRank(rank)
            return rank
        }
        emptyRankRequests[pageID] = PaletteEmptyRankRequest(token: token, version: input.version,
                                                            frecencyRevision: revision, task: task)
        return task
    }

    /// Usage changed: ranks the most recently ranked page again now (the page the next open most
    /// likely shows), so it opens on the new order. Other kept pages rank again when they open.
    /// A page with a rank in flight keeps it: a search on screen waits for that rank.
    func prewarmEmptyRanks() {
        guard let pageID = emptyRankOrder.last, emptyRankRequests[pageID] == nil,
              let rank = emptyRanks[pageID], rank.frecencyRevision != frecencyRevision else { return }
        _ = requestEmptyRank(rank.input)
    }

    private func storeEmptyRank(_ rank: PaletteEmptyRank) {
        let pageID = rank.input.pageID
        emptyRanks[pageID] = rank
        emptyRankOrder.removeAll { $0 == pageID }
        emptyRankOrder.append(pageID)
        while emptyRankOrder.count > Self.emptyRankPageLimit {
            emptyRanks[emptyRankOrder.removeFirst()] = nil
        }
    }

    /// The page's empty-query rows in provider order, grouped by section in section order: the
    /// first open's rows until the first rank lands.
    static func unranked(_ state: PageState) -> [PaletteResultSection] {
        let items = state.items
        let sections = state.sections
        var rows: [Int: [PaletteRow]] = [:]
        for (position, entry) in state.entries.enumerated()
        where entry.isVisibleWhenQueryEmpty && items.indices.contains(position) && sections.indices.contains(entry.sectionIndex) {
            rows[entry.sectionIndex, default: []].append(PaletteRow(item: items[position], highlights: [], score: 0))
        }
        return rows.keys
            .sorted { (sections[$0].order, $0) < (sections[$1].order, $1) }
            .compactMap { index in rows[index].map { PaletteResultSection(section: sections[index], rows: $0) } }
    }
}
