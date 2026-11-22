import Foundation

/// A contributed page that finds its own rows for each query (`PalettePageSpec.queryResults`, the
/// agent chats page asks acpmux), joined into Search and the Chats & agents scope. Such a page has
/// no rows to rank in advance, so the palette asks it for the typed query beside the page's own
/// ranked search and shows its answer under the contribution's section.
struct PaletteContributedAnswers {
    /// The section its rows show under (the contribution's), unless a row carries its own.
    let section: PaletteSection
    /// The page's main content (the Chats & agents scope's chats): asked for the empty query too,
    /// shown first, and its query's rows are not final until it answers, so a Return waits for it as
    /// on the page itself. Otherwise (Search) it is asked for typed queries only and shows after the
    /// best ranked section; it holds the rows from being final only while the query has no ranked row.
    let leads: Bool
    /// The page's answers for a query (`PalettePageSpec.queryResults`).
    let results: @MainActor (String) -> AsyncStream<[PaletteItem]>
    /// The page's cancel (`PalettePageSpec.onCancel`): it releases what its queries hold (acpmux's window).
    let close: (@MainActor () -> Void)?
    /// The row Search shows when it cuts the answer (`PalettePageSpec.moreRow`).
    let moreRow: (@MainActor (_ notShown: Int, _ query: String) -> PaletteItem)?
    /// The page's source-change subscription (`PalettePageSpec.onSourceChange`).
    let onSourceChange: (@MainActor (@escaping @MainActor () -> Void) -> AnyObject)?

    /// Every Search page shows at most this many rows (the ranker's `rowLimit`, `PaletteRanker.rank`).
    static let pageRowLimit = 400
    /// The fewest rows an answer that does not lead shows in Search (its best ones). It gets every row the
    /// ranked rows leave under `pageRowLimit`, and at least these, taken from the weakest ranked rows: a
    /// one-letter query that fills the page still shows the best chats. A cut answer ends with its page's
    /// `moreRow`, which says how many more match and opens the page with the query.
    static let searchShare = 10
}

extension PaletteModel {
    /// Asks the page's contributed answers for the state's query, once per query: a re-search of the
    /// same query (a provider's rows changed) keeps the answers it has. A new query cancels the old
    /// query's streams; their rows stay on screen as stand-ins only (never selectable, never final) until
    /// the new answers replace them, and leave when an answer ends with no rows (acpmux refused it or is
    /// not connected). The page is asked in a later turn than the key's, and each answer lands later still.
    func askContributions(_ state: PageState, page: PalettePageSpec) {
        guard !page.contributedAnswers.isEmpty, state.answeredQuery != state.query else { return }
        let query = state.query
        state.answeredQuery = query
        state.cancelAnswerTasks()
        let empty = query.allSatisfy(\.isWhitespace)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for contribution in page.contributedAnswers {
            let section = contribution.section
            if contribution.leads { state.leadingAnswers.insert(section.id) }
            guard !empty || contribution.leads else {
                state.answerSections[section.id] = nil
                state.answerQueries[section.id] = nil
                continue
            }
            state.awaitedAnswers.insert(section.id)
            // task-owner: the page state's answerTasks; cancelled by the next query or when the page is left
            // Every request ends: with rows, with none (refused, not ready, not connected, no match), or when the
            // query moves on; so the rows wait for it with no timer.
            state.answerTasks.append(Task { [weak self, weak state] in
                guard let current = state, current.answeredQuery == query else { return }
                let answers = contribution.results(query)
                var answered = false
                for await items in answers {
                    guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                    answered = !items.isEmpty
                    let rows = items.map { item in
                        var item = item
                        if item.section.id == PaletteSection.results.id { item.section = section }
                        return PaletteRow(item: item, highlights: Self.wordHighlights(in: item.title, words: words), score: 0)
                    }
                    state.answerSections[section.id] = rows.isEmpty ? nil : PaletteResultSection(section: section, rows: rows)
                    state.answerQueries[section.id] = rows.isEmpty ? nil : query
                    self.scheduleRedelivery(state)
                }
                // The query's answer is complete. None (refused, not connected, no match): its stand-ins leave.
                guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                if !answered {
                    state.answerSections[section.id] = nil
                    state.answerQueries[section.id] = nil
                }
                state.awaitedAnswers.remove(section.id)
                self.scheduleRedelivery(state)
            })
        }
    }

    /// Subscribes to the page's sources (its own `queryResults` and its contributed answers): when one can
    /// answer again (acpmux connected, its index ready), the shown query is asked again. Once per page state.
    func followSources(_ state: PageState, page: PalettePageSpec) {
        guard state.sourceTokens.isEmpty else { return }
        let subscriptions = [page.onSourceChange] + page.contributedAnswers.map(\.onSourceChange)
        for subscribe in subscriptions.compactMap({ $0 }) {
            state.sourceTokens.append(subscribe { [weak self, weak state] in
                guard let self, let state, self.pages[state.levelID] === state else { return }
                state.answeredQuery = nil
                self.search(state)
            })
        }
    }

    /// Redelivers the page's rows with its answers once in this main-thread turn, however many answers changed in
    /// it (a yield and the stream's end come together).
    func scheduleRedelivery(_ state: PageState) {
        guard !state.redeliveryScheduled else { return }
        state.redeliveryScheduled = true
        // task-owner: one main-actor hop per turn that changed an answer; it ends at once
        Task { @MainActor [weak self, weak state] in
            guard let state else { return }
            state.redeliveryScheduled = false
            self?.redeliverAnswers(state)
        }
    }

    /// Shows the ranked rows again with the answers, only when those ranked rows are the current
    /// query's (an answer that lands first waits for them: the rank's own delivery adds it), and only when what
    /// a delivery would show or hold changed: an answer that changes nothing on screen (an empty one, with no
    /// stand-ins to take off) costs no list reload and no reducer pass. When the rows above the selected one
    /// grew, the list scrolls to keep the selected row in view.
    func redeliverAnswers(_ state: PageState) {
        guard let ranked = state.rankedSections, state.rankedGeneration == state.generation else { return }
        guard Self.answerFingerprint(state) != state.deliveredAnswerFingerprint else { return }
        let shown = state === current
        let before = shown ? rows.firstIndex { $0.id == selectedRowID } : nil
        deliver(ranked, to: state, generation: state.generation, provisional: state.rankedProvisional,
                complete: state.rankedComplete)
        if shown, let before, let after = rows.firstIndex(where: { $0.id == selectedRowID }), after != before {
            scrollRequest += 1
        }
    }

    /// What a delivery shows and what navigation may select: `shown` has the current answers and the
    /// stand-ins, `selectable` only the current answers. `held`: the rows are not final, so a Return waits
    /// (the page waits for its leading answer, or has no ranked row while an answer is still awaited).
    static func joined(_ ranked: [PaletteResultSection], state: PageState)
        -> (shown: [PaletteResultSection], selectable: [PaletteResultSection], held: Bool) {
        let current = state.currentAnswers, standIns = state.standInAnswers
        let held = isHeld(ranked, state: state)
        guard !current.isEmpty || !standIns.isEmpty else { return (ranked, ranked, held) }
        let more = state.moreRows(forQuery: state.query)
        let shown = withAnswers(ranked, answers: current + standIns, leading: state.leadingAnswers, more: more)
        // The same rows without the stand-in sections: one cut of the ranked rows for both, so every row
        // navigation may select is on screen.
        let standInIDs = Set(standIns.map(\.section.id))
        let selectable = standIns.isEmpty ? shown : shown.filter { !standInIDs.contains($0.section.id) }
        return (shown, selectable, held)
    }

    /// Whether the rows are held (not final, so a Return waits): the page waits for its leading answer, or the
    /// query has no ranked row while an answer is still awaited.
    static func isHeld(_ ranked: [PaletteResultSection], state: PageState) -> Bool {
        state.awaitsLead || (!ranked.contains { !$0.rows.isEmpty } && !state.awaitedAnswers.isEmpty)
    }

    /// What the page's answers make a delivery show and hold: each answer section's rows as they show (id, title,
    /// subtitle, accessory, enabled; a notice row's title carries its count) and the query they answer, and whether
    /// the rows are held. Not the raw awaited set: an awaited answer that ends empty while the query has ranked rows
    /// changes nothing a delivery shows or holds. Equal fingerprints deliver the same rows with the same final mark.
    static func answerFingerprint(_ state: PageState) -> [String] {
        var parts = state.answerSections.keys.sorted().map { id in
            "\(id)|\(state.answerQueries[id] ?? "")|" + (state.answerSections[id]?.rows.map { row in
                let item = row.item
                return [item.id, item.title, item.subtitle ?? "", item.accessory ?? "", item.isEnabled ? "1" : "0"]
                    .joined(separator: "\u{1F}")
            }.joined(separator: "\u{1E}") ?? "")
        }
        parts.append("held:\(isHeld(state.rankedSections ?? [], state: state))")
        parts.append("query:" + state.query)
        return parts
    }

    /// `ranked` with the answers: a leading answer first, any other after the best ranked section (where
    /// the ranker put the best row) with every row the ranked rows leave under `pageRowLimit` and at least
    /// `searchShare`. A cut answer keeps its best rows and ends with `more` (its page's row that says how many
    /// more match). The ranked rows give up their weakest rows so the page keeps to `pageRowLimit`.
    static func withAnswers(_ ranked: [PaletteResultSection], answers: [PaletteResultSection], leading: Set<String>,
                            more: [String: (_ notShown: Int) -> PaletteItem] = [:]) -> [PaletteResultSection] {
        let ordered = answers.sorted { ($0.section.order, $0.section.id) < ($1.section.order, $1.section.id) }
        let leads = ordered.filter { leading.contains($0.section.id) }
        var room = PaletteContributedAnswers.pageRowLimit - ranked.reduce(0) { $0 + $1.rows.count }
            - leads.reduce(0) { $0 + $1.rows.count }
        var others: [PaletteResultSection] = []
        for answer in ordered where !leading.contains(answer.section.id) {
            let share = max(PaletteContributedAnswers.searchShare, room)
            var rows = answer.rows
            // The page's own notices (disabled rows: "the best 200 of N") stay while nothing is cut.
            let entries = rows.filter(\.item.isEnabled)
            if entries.count > share {
                rows = Array(entries.prefix(share))
                if let more = more[answer.section.id] {
                    var item = more(entries.count - share)
                    if item.section.id == PaletteSection.results.id { item.section = answer.section }
                    rows.append(PaletteRow(item: item, highlights: [], score: 0))
                }
            }
            room -= rows.count
            others.append(PaletteResultSection(section: answer.section, rows: rows))
        }
        let answerRows = (leads + others).reduce(0) { $0 + $1.rows.count }
        let kept = trimmed(ranked, to: max(0, PaletteContributedAnswers.pageRowLimit - answerRows))
        let split = min(1, kept.count)
        var sections = leads
        sections += kept.prefix(split)
        sections += others
        sections += kept.dropFirst(split)
        return sections
    }

    /// `sections` with at most `limit` rows, the last (weakest) rows dropped first.
    static func trimmed(_ sections: [PaletteResultSection], to limit: Int) -> [PaletteResultSection] {
        var room = limit
        var kept: [PaletteResultSection] = []
        for section in sections where room > 0 {
            let rows = Array(section.rows.prefix(room))
            room -= rows.count
            kept.append(PaletteResultSection(section: section.section, rows: rows))
        }
        return kept
    }
}
