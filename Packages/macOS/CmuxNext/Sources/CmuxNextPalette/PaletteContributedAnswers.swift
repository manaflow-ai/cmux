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

    /// Every Search page shows at most this many rows (the ranker's `rowLimit`, `PaletteRanker.rank`);
    /// an answer that does not lead gets the rows the ranked ones leave, its weakest rows dropped.
    static let pageRowLimit = 400
}

extension PaletteModel {
    /// Asks the page's contributed answers for the state's query, once per query: a re-search of the
    /// same query (a provider's rows changed) keeps the answers it has. A new query cancels the old
    /// query's streams but keeps their rows on screen until its own answers replace them. The page is
    /// asked in a later turn than the key's, and each answer lands in a later turn still.
    func askContributions(_ state: PageState, page: PalettePageSpec) {
        guard !page.contributedAnswers.isEmpty, state.answeredQuery != state.query else { return }
        let query = state.query
        state.answeredQuery = query
        state.cancelAnswerTasks()
        let empty = query.allSatisfy(\.isWhitespace)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for contribution in page.contributedAnswers {
            let section = contribution.section
            guard !empty || contribution.leads else {
                state.answerSections[section.id] = nil
                continue
            }
            if contribution.leads {
                state.leadingAnswers.insert(section.id)
                state.pendingLeads.insert(section.id)
            }
            state.answerTasks.append(Task { [weak self, weak state] in
                guard let current = state, current.answeredQuery == query else { return }
                let answers = contribution.results(query)
                var answered = false
                for await items in answers {
                    guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                    answered = true
                    let rows = items.map { item in
                        var item = item
                        if item.section.id == PaletteSection.results.id { item.section = section }
                        return PaletteRow(item: item, highlights: Self.wordHighlights(in: item.title, words: words), score: 0)
                    }
                    state.answerSections[section.id] = rows.isEmpty ? nil : PaletteResultSection(section: section, rows: rows)
                    self.redeliverAnswers(state)
                }
                // The query's answer is complete: it no longer holds the rows from being final.
                guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                if !answered { state.answerSections[section.id] = nil }
                state.pendingLeads.remove(section.id)
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

    /// `ranked` with the answers: a leading answer first, any other after the best ranked section
    /// (where the ranker put the best row), capped to the rows the page has left.
    static func withAnswers(_ ranked: [PaletteResultSection], answers: [PaletteResultSection],
                            leading: Set<String>) -> [PaletteResultSection] {
        let ordered = answers.sorted { ($0.section.order, $0.section.id) < ($1.section.order, $1.section.id) }
        let leads = ordered.filter { leading.contains($0.section.id) }
        var room = PaletteContributedAnswers.pageRowLimit - ranked.reduce(0) { $0 + $1.rows.count }
        var others: [PaletteResultSection] = []
        for answer in ordered where !leading.contains(answer.section.id) && room > 0 {
            let rows = Array(answer.rows.prefix(room))
            room -= rows.count
            others.append(PaletteResultSection(section: answer.section, rows: rows))
        }
        let split = min(1, ranked.count)
        var sections = leads
        sections += ranked.prefix(split)
        sections += others
        sections += ranked.dropFirst(split)
        return sections
    }
}
