import CmuxCommandPalette
import CmuxFoundation
import SwiftUI

/// Compact tab-name search pinned at the top-left of the workspace sidebar.
///
/// Typing filters every workspace (vertical tab) and surface (horizontal tab)
/// by name and shows a dropdown of hits grouped into a Workspaces section and a
/// Tabs section. Selecting a hit — click or Enter on the top hit — focuses that
/// workspace/surface. It reuses the Cmd-P switcher corpus (via `entriesProvider`)
/// so ranking, keywords, and the focus action match the command palette.
///
/// The dropdown is an eager `VStack` of immutable ``SidebarTabSearchResult``
/// value rows (no `LazyVStack`, no store references), so it stays clear of the
/// sidebar lazy-layout snapshot boundary (CLAUDE.md / issue #2586).
struct SidebarTabSearchView: View {
    /// Supplies the current switcher corpus (workspaces + surfaces) with
    /// ready-made navigation actions. Backed by
    /// `ContentView.commandPaletteSwitcherEntries(includeSurfaces:)`.
    let entriesProvider: () -> [CommandPaletteCommand]

    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool
    @State private var results: [SidebarTabSearchResult] = []
    @State private var actionsById: [String: () -> Void] = [:]

    private static let resultLimit = 40
    private static let workspaceIdPrefix = "switcher.workspace."
    /// Debounce window: coalesces keystroke bursts before rebuilding the corpus.
    private static let debounceNanoseconds: UInt64 = 120_000_000

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var workspaceResults: [SidebarTabSearchResult] {
        results.filter { $0.kind == .workspace }
    }

    private var tabResults: [SidebarTabSearchResult] {
        results.filter { $0.kind == .tab }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
            if isSearching {
                resultsDropdown
            }
        }
        // `.task(id:)` reruns on every keystroke and cancels the prior run (and
        // its debounce sleep), so the sleep below is a bounded, cancellable
        // delay rather than a poll.
        .task(id: query) {
            await refreshResults()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 11, weight: .medium)
                .foregroundColor(.secondary)
            TextField(
                String(
                    localized: "sidebar.tabSearch.placeholder",
                    defaultValue: "Search tabs"
                ),
                text: $query
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 12)
            .focused($fieldFocused)
            .onSubmit { runTopResult() }
            if !query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "sidebar.tabSearch.clear",
                        defaultValue: "Clear tab search"
                    )
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var resultsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(
                    String(
                        localized: "sidebar.tabSearch.noMatches",
                        defaultValue: "No matching tabs"
                    )
                )
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        resultSection(
                            title: String(
                                localized: "sidebar.tabSearch.section.workspaces",
                                defaultValue: "Workspaces"
                            ),
                            rows: workspaceResults
                        )
                        resultSection(
                            title: String(
                                localized: "sidebar.tabSearch.section.tabs",
                                defaultValue: "Tabs"
                            ),
                            rows: tabResults
                        )
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }

    @ViewBuilder
    private func resultSection(title: String, rows: [SidebarTabSearchResult]) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased())
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(rows) { row in
                SidebarTabSearchResultRow(
                    result: row,
                    isTopHit: row.id == results.first?.id,
                    onSelect: { run(row) }
                )
            }
        }
    }

    private func refreshResults() async {
        guard isSearching else {
            results = []
            actionsById = [:]
            return
        }

        // Bounded, cancellable debounce. See `.task(id:)` note on `body`.
        try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
        if Task.isCancelled { return }

        let ranked = rank(trimmedQuery)
        if Task.isCancelled { return }

        actionsById = ranked.actions
        results = ranked.results
    }

    /// Builds the switcher corpus and ranks it for `query`, synchronously. The
    /// corpus build and ranking are cheap, so this doubles as the Enter path so
    /// pressing Return acts on the current query even before the debounced
    /// `refreshResults()` has run (otherwise a fast type-then-Enter would fire
    /// on the previous query's results, or on none at all).
    private func rank(_ query: String) -> (results: [SidebarTabSearchResult], actions: [String: () -> Void]) {
        let commands = entriesProvider()
        var actions: [String: () -> Void] = [:]
        actions.reserveCapacity(commands.count)
        let candidates: [SidebarTabSearchCandidate] = commands.map { command in
            actions[command.id] = command.action
            return SidebarTabSearchCandidate(
                id: command.id,
                rank: command.rank,
                title: command.title,
                subtitle: command.subtitle,
                kindLabel: command.kindLabel,
                keywords: command.keywords,
                // The switcher ids are `switcher.workspace.*` / `switcher.surface.*`;
                // anything that is not a workspace row is a tab (surface) row.
                kind: command.id.hasPrefix(Self.workspaceIdPrefix) ? .workspace : .tab
            )
        }
        let ranked = SidebarTabSearchIndex(candidates: candidates)
            .rankedResults(matching: query, limit: Self.resultLimit)
        return (ranked, actions)
    }

    private func runTopResult() {
        let query = trimmedQuery
        guard !query.isEmpty else { return }
        let ranked = rank(query)
        guard let top = ranked.results.first, let action = ranked.actions[top.id] else { return }
        action()
        clear()
    }

    private func run(_ result: SidebarTabSearchResult) {
        actionsById[result.id]?()
        clear()
    }

    private func clear() {
        query = ""
        results = []
        fieldFocused = false
    }
}

/// One dropdown row: kind icon, highlighted title, and the workspace context /
/// kind label. Holds only value data plus its select closure, never a store.
private struct SidebarTabSearchResultRow: View {
    let result: SidebarTabSearchResult
    let isTopHit: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    highlightedTitle
                        .cmuxFont(size: 12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let kindLabel = result.kindLabel, result.kind == .tab {
                    Text(kindLabel)
                        .cmuxFont(size: 9, weight: .medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTopHit ? Color.accentColor.opacity(0.14) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        result.kind == .workspace ? "rectangle.stack" : "rectangle"
    }

    /// Bolds/colors the title characters the fuzzy matcher matched, mirroring
    /// `ContentView.commandPaletteHighlightedTitleText`.
    private var highlightedTitle: Text {
        guard !result.titleMatchIndices.isEmpty else {
            return Text(result.title).foregroundColor(.primary)
        }
        let chars = Array(result.title)
        var index = 0
        var text = Text("")
        while index < chars.count {
            let isMatched = result.titleMatchIndices.contains(index)
            var end = index + 1
            while end < chars.count, result.titleMatchIndices.contains(end) == isMatched {
                end += 1
            }
            let segment = String(chars[index..<end])
            text = text + Text(segment).foregroundColor(isMatched ? .accentColor : .primary)
            index = end
        }
        return text
    }
}
