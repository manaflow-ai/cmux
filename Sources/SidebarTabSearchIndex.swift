import CmuxCommandPalette
import Foundation

/// One tab-search candidate: either a workspace (a vertical sidebar tab) or a
/// surface (a horizontal tab inside a workspace), reduced to the value fields
/// the fuzzy ranker and the result row need.
///
/// Sendable so ranking can move off the main actor later without reshaping the
/// type. The `id` mirrors the originating ``CommandPaletteCommand.id`` (for
/// example `switcher.workspace.<uuid>` / `switcher.surface.<uuid>`) so the view
/// can look the navigation action back up after ranking.
struct SidebarTabSearchCandidate: Sendable, Identifiable {
    /// Whether the candidate is a workspace row or a surface (tab) row.
    enum Kind: Sendable {
        case workspace
        case tab
    }

    let id: String
    /// Tie-break rank; lower sorts first at equal fuzzy score. Preserves the
    /// switcher's ordering (selected workspace first, then declaration order).
    let rank: Int
    let title: String
    let subtitle: String
    let kindLabel: String?
    let keywords: [String]
    let kind: Kind
}

/// One ranked tab-search hit: an immutable value snapshot handed down to the
/// results list.
///
/// Carries `titleMatchIndices` for highlighting and carries no closure and no
/// store reference, so result rows stay below the sidebar snapshot boundary
/// (see the LazyVStack/`@Observable` rule in CLAUDE.md / issue #2586).
struct SidebarTabSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kindLabel: String?
    let kind: SidebarTabSearchCandidate.Kind
    let titleMatchIndices: Set<Int>
}

/// Fuzzy tab-name index over a window's workspaces and surfaces.
///
/// Reuses the shared command-palette matcher and ranking engine
/// (``CommandPaletteFuzzyMatcher`` / ``CommandPaletteSearchEngine``) so ranking
/// and highlight indices match the Cmd-P switcher exactly rather than diverging
/// into a third matcher.
struct SidebarTabSearchIndex: Sendable {
    private let corpus: [CommandPaletteSearchCorpusEntry<SidebarTabSearchCandidate>]

    /// Builds a corpus entry per candidate, indexing its title plus its
    /// subtitle and derived keywords (directory / branch / port context).
    init(candidates: [SidebarTabSearchCandidate]) {
        corpus = candidates.map { candidate in
            CommandPaletteSearchCorpusEntry(
                payload: candidate,
                rank: candidate.rank,
                title: candidate.title,
                searchableTexts: [candidate.title, candidate.subtitle] + candidate.keywords
            )
        }
    }

    /// Returns up to `limit` hits for `rawQuery`, most relevant first. An empty
    /// (or whitespace-only) query returns no hits: the sidebar shows its normal
    /// workspace list until the user actually types.
    func rankedResults(matching rawQuery: String, limit: Int) -> [SidebarTabSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !query.isEmpty else { return [] }

        let prefiltered = Self.prefilter(corpus, query: query)
        guard !prefiltered.isEmpty else { return [] }

        return CommandPaletteSearchEngine(entries: prefiltered)
            .search(query: query, resultLimit: limit, historyBoost: { _, _ in 0 })
            .map { result in
                SidebarTabSearchResult(
                    id: result.payload.id,
                    title: result.title,
                    subtitle: result.payload.subtitle,
                    kindLabel: result.payload.kindLabel,
                    kind: result.payload.kind,
                    titleMatchIndices: result.titleMatchIndices
                )
            }
    }

    /// Cheap ASCII-mask token pre-filter (mirrors ``TextBoxMentionCandidateIndex``)
    /// so the O(n) engine scores only plausible candidates.
    private static func prefilter(
        _ entries: [CommandPaletteSearchCorpusEntry<SidebarTabSearchCandidate>],
        query: String
    ) -> [CommandPaletteSearchCorpusEntry<SidebarTabSearchCandidate>] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        guard !preparedQuery.isEmpty else { return entries }
        return entries.filter { entry in
            preparedQuery.tokens.allSatisfy { token in
                entry.preparedSearchableTexts.contains { candidate in
                    CommandPaletteFuzzyMatcher.tokenCanMatchWithoutSingleEdit(
                        token,
                        preparedCandidate: candidate
                    )
                }
            }
        }
    }
}
