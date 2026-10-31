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
    /// on the page itself. Otherwise (Search) it is asked for typed queries only, shows after the
    /// best ranked section and never holds the rows from being final.
    let leads: Bool
    /// The page's answers for a query (`PalettePageSpec.queryResults`).
    let results: @MainActor (String) -> AsyncStream<[PaletteItem]>
    /// The page's cancel (`PalettePageSpec.onCancel`): it releases what its queries hold (acpmux's window).
    let close: (@MainActor () -> Void)?

    /// Every Search page shows at most this many rows (the ranker's `rowLimit`, `PaletteRanker.rank`).
    static let pageRowLimit = 400
    /// The rows an answer that does not lead always shows in Search (its best ones), taken from the weakest
    /// ranked rows when the page is full: a one-letter query that fills the page still shows the best chats.
    static let searchShare = 10
    /// How long a query's Return waits for an answer still in flight (acpmux answers in a few ms; a refused
    /// or disconnected request ends at once). Past it the rows are final without the answer, which still shows
    /// when it lands.
    static let holdLimit: Duration = .milliseconds(1500)
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
                    self.redeliverAnswers(state)
                }
                // The query's answer is complete. None (refused, not connected, no match): its stand-ins leave.
                guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                if !answered {
                    state.answerSections[section.id] = nil
                    state.answerQueries[section.id] = nil
                }
                state.awaitedAnswers.remove(section.id)
                self.redeliverAnswers(state)
            })
            // task-owner: the page state's answerTasks; the bound on how long the query's rows wait for this answer
            state.answerTasks.append(Task { [weak self, weak state] in
                // wakeup-allow: one one-shot bound per asked query; it decides only when the rows stop waiting, never whether the answer shows
                guard (try? await Task.sleep(for: PaletteContributedAnswers.holdLimit)) != nil else { return }
                guard let self, let state, state.answeredQuery == query, state.awaitedAnswers.remove(section.id) != nil else { return }
                self.redeliverAnswers(state)
            })
        }
    }

    /// Shows the ranked rows again with the answers, only when those ranked rows are the current
    /// query's (an answer that lands first waits for them: the rank's own delivery adds it). When the
    /// rows above the selected one grew, the list scrolls to keep the selected row in view.
    func redeliverAnswers(_ state: PageState) {
        guard let ranked = state.rankedSections, state.rankedGeneration == state.generation else { return }
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
        let rankedRows = ranked.reduce(0) { $0 + $1.rows.count }
        let held = state.awaitsLead || (rankedRows == 0 && !state.awaitedAnswers.isEmpty)
        guard !current.isEmpty || !standIns.isEmpty else { return (ranked, ranked, held) }
        let shown = withAnswers(ranked, answers: current + standIns, leading: state.leadingAnswers)
        let selectable = standIns.isEmpty ? shown : withAnswers(ranked, answers: current, leading: state.leadingAnswers)
        return (shown, selectable, held)
    }

    /// `ranked` with the answers: a leading answer first, any other after the best ranked section (where
    /// the ranker put the best row) with its best `searchShare` rows. The ranked rows give up their weakest
    /// rows so the page keeps to `pageRowLimit`.
    static func withAnswers(_ ranked: [PaletteResultSection], answers: [PaletteResultSection],
                            leading: Set<String>) -> [PaletteResultSection] {
        let ordered = answers.sorted { ($0.section.order, $0.section.id) < ($1.section.order, $1.section.id) }
        let leads = ordered.filter { leading.contains($0.section.id) }
        let others = ordered.filter { !leading.contains($0.section.id) }.map {
            PaletteResultSection(section: $0.section, rows: Array($0.rows.prefix(PaletteContributedAnswers.searchShare)))
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
