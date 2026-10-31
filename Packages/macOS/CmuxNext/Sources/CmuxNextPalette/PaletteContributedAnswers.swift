import Foundation

/// A contributed page that finds its own rows for each query (`PalettePageSpec.queryResults`, the
/// agent chats page asks acpmux), joined into Search and the Chats & agents scope. Such a page has
/// no rows to rank in advance, so the palette asks it for the typed query beside the page's own
/// ranked search and shows its answer under the contribution's section.
struct PaletteContributedAnswers {
    /// The section its rows show under (the contribution's), unless a row carries its own.
    let section: PaletteSection
    /// Whether the page is asked before anything is typed (the Chats & agents scope lists the newest).
    let showsForEmptyQuery: Bool
    /// The page's answers for a query (`PalettePageSpec.queryResults`).
    let results: @MainActor (String) -> AsyncStream<[PaletteItem]>
    /// The page's cancel (`PalettePageSpec.onCancel`): it releases what its queries hold (acpmux's window).
    let close: (@MainActor () -> Void)?
}

extension PaletteModel {
    /// Asks the page's contributed answers for the state's query, once per query: a re-search of the
    /// same query (a provider's rows changed) keeps the answers it has. A new query drops the old
    /// query's answers and cancels their streams. Each answer lands in a later turn and shows with the
    /// ranked rows on screen; the answers never hold the page's rows from being final, so Return never
    /// waits for an answer that may not come.
    func askContributions(_ state: PageState, page: PalettePageSpec) {
        guard !page.contributedAnswers.isEmpty, state.answeredQuery != state.query else { return }
        let query = state.query
        state.answeredQuery = query
        state.cancelAnswers()
        let empty = query.allSatisfy(\.isWhitespace)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for contribution in page.contributedAnswers where !empty || contribution.showsForEmptyQuery {
            let answers = contribution.results(query)
            let section = contribution.section
            state.answerTasks.append(Task { [weak self, weak state] in
                for await items in answers {
                    guard !Task.isCancelled, let self, let state, state.answeredQuery == query else { return }
                    let rows = items.map { item in
                        var item = item
                        if item.section.id == PaletteSection.results.id { item.section = section }
                        return PaletteRow(item: item, highlights: Self.wordHighlights(in: item.title, words: words), score: 0)
                    }
                    state.answerSections[section.id] = rows.isEmpty ? nil : PaletteResultSection(section: section, rows: rows)
                    self.redeliverAnswers(state)
                }
            })
        }
    }

    /// Shows the state's ranked rows again with its answers (the answers alone before any rank landed).
    func redeliverAnswers(_ state: PageState) {
        deliver(state.rankedSections ?? [], to: state, generation: state.generation, provisional: state.awaitsRank)
    }

    /// `ranked` with each answer section placed before the first ranked section of a later order.
    static func withAnswers(_ ranked: [PaletteResultSection], answers: [PaletteResultSection]) -> [PaletteResultSection] {
        var sections = ranked
        for answer in answers.sorted(by: { ($0.section.order, $0.section.id) < ($1.section.order, $1.section.id) }) {
            let index = sections.firstIndex { $0.section.order > answer.section.order } ?? sections.endIndex
            sections.insert(answer, at: index)
        }
        return sections
    }
}
