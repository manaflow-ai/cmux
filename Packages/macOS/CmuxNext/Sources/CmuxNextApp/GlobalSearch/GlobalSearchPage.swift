import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette

/// Search All Windows as a palette page that searches as you type: one row
/// per matching tab, titled with its newest matching line (or its title
/// when only that matched) and subtitled with where it is.
@MainActor
enum GlobalSearchPage {
    /// A searched tab, as the rows show and reveal it.
    struct Tab {
        let source: GlobalSearchCorpus.Source
        /// The title the tab strip shows (`TabTitleResolver`).
        let title: String
        let located: LocatedTab
        /// An agent chat with no title of its own is named by its workspace: shown once.
        var place: String {
            let workspace = located.workspace.displayName
            return title == workspace ? workspace : "\(workspace) › \(title)"
        }
    }

    /// Shows a tab and, given a needle, runs its terminal's Find for it.
    typealias Reveal = @MainActor (LocatedTab, _ needle: String?) -> Void

    static let pageID = "globalSearch.results"

    /// The page, reading `tabs` once as it opens; `query` is its starting text.
    /// A query is answered at once from what has been read so far (every
    /// title from the start), and again as each terminal and transcript is
    /// read: a slow or unreachable machine never holds back the rest.
    static func page(query: String, tabs: [Tab], reveal: @escaping Reveal) -> PalettePageSpec {
        let corpus = GlobalSearchReader(tabs.map(\.source))
        let byTab = Dictionary(tabs.map { ($0.source.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        return PalettePageSpec(
            id: pageID, title: GlobalSearchStrings.title, placeholder: GlobalSearchStrings.placeholder, symbol: "magnifyingglass",
            providers: [], initialQuery: query,
            // The page is left: a read still running has no one to answer.
            onCancel: { corpus.release() },
            queryResults: { query in
                answers(query, corpus: corpus, byTab: byTab, reveal: reveal)
            },
            filtersByQuery: false)
    }

    /// The rows for `query` from each state of `corpus`'s read: first from
    /// what is read now, then once per change, the last when the read ends.
    static func answers(_ query: String, corpus: GlobalSearchReader, byTab: [String: Tab],
                        reveal: @escaping Reveal) -> AsyncStream<[PaletteItem]> {
        let words = GlobalSearchCorpus.words(query)
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        guard !words.isEmpty else {
            continuation.yield([notice(GlobalSearchStrings.prompt, id: "prompt")])
            continuation.finish()
            return stream
        }
        // task-owner: the palette's search of this query; ending the stream (a newer query) cancels it.
        let task = Task { @MainActor in
            for await state in corpus.states() {
                let found = await state.value.hits(words)
                guard !Task.isCancelled else { break }
                // Nothing yet while reading: the rows on screen stay the older query's, so a
                // Return pressed now waits for the first hit instead of running no row.
                if found.hits.isEmpty, !state.complete { continue }
                // The palette keeps a closed page until its next open: a chosen row lets the text go.
                continuation.yield(items(found.hits, limited: found.limited, unreadable: state.value.unreadable, words: words,
                                         byTab: byTab, reading: !state.complete, reveal: reveal, done: { corpus.release() }))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// `reading`: more text is on its way, so no "No matches" or "not read" yet (the field's spinner runs).
    static func items(_ hits: [GlobalSearchCorpus.Hit], limited: Bool, unreadable: Int, words: [String],
                      byTab: [String: Tab], reading: Bool = false, reveal: @escaping Reveal,
                      done: @escaping @MainActor () -> Void) -> [PaletteItem] {
        var rows = hits.compactMap { hit in byTab[hit.tabID].map { item(hit, words: words, in: $0, reveal: reveal, done: done) } }
        if rows.isEmpty, !reading { rows.append(notice(GlobalSearchStrings.noMatches, id: "none")) }
        if limited { rows.append(notice(GlobalSearchStrings.limited(GlobalSearchCorpus.limit), id: "limited")) }
        if unreadable > 0, !reading { rows.append(notice(GlobalSearchStrings.unreadable(unreadable), id: "unreadable")) }
        return rows
    }

    private static func item(_ hit: GlobalSearchCorpus.Hit, words: [String], in tab: Tab, reveal: @escaping Reveal,
                             done: @escaping @MainActor () -> Void) -> PaletteItem {
        let located = tab.located
        let line = hit.line
        // Find runs only where the line is terminal text; a transcript line may be nowhere on screen.
        let needle = hit.origin == .terminal ? line.map { GlobalSearchCorpus.needle(in: $0, words: words) } : nil
        var subtitle = tab.place
        if case .transcript(let harness) = hit.origin { subtitle += " · " + GlobalSearchStrings.agentName(harness) }
        var secondary: [PaletteCommand] = []
        if let line {
            secondary.append(PaletteCommand(id: "copyLine", title: GlobalSearchStrings.copyLine, symbol: "doc.on.doc", effect: .perform {
                done()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }))
        }
        return PaletteItem(
            id: "globalSearch.tab.\(hit.tabID)",
            title: line.map { GlobalSearchCorpus.snippet($0, words: words) } ?? tab.title,
            subtitle: subtitle,
            accessory: hit.count > 1 ? GlobalSearchStrings.matches(hit.count) : nil,
            symbol: symbol(hit, kind: located.tab.kind),
            primary: PaletteCommand(id: "show", title: GlobalSearchStrings.show, symbol: "return",
                                    effect: .perform {
                                        done()
                                        reveal(located, needle)
                                    }),
            secondary: secondary)
    }

    private static func symbol(_ hit: GlobalSearchCorpus.Hit, kind: TabKind) -> String {
        if case .transcript = hit.origin { return "bubble.left.and.text.bubble.right" }
        switch kind {
        case .browser: return "globe"
        case .conversation: return "bubble.left"
        default: return "terminal"
        }
    }

    private static func notice(_ text: String, id: String) -> PaletteItem {
        PaletteItem(id: "globalSearch.notice.\(id)", title: text, symbol: "info.circle", isEnabled: false, primary:
            PaletteCommand(id: "none", title: text, effect: .performKeepingOpen {}))
    }
}

/// The page's text: every title at once, each terminal's and transcript's text as its read ends.
typealias GlobalSearchReader = PaletteLiveRead<GlobalSearchCorpus>

extension PaletteLiveRead where Value == GlobalSearchCorpus {
    /// Reads `sources` (or the given `reads`, tests) as the page opens.
    convenience init(_ sources: [GlobalSearchCorpus.Source], reads: AsyncStream<GlobalSearchCorpus.Read>? = nil) {
        self.init(GlobalSearchCorpus(titles: sources), empty: GlobalSearchCorpus(), updates: reads ?? GlobalSearchCorpus.reads(sources)) {
            $0.apply($1)
        }
    }
}

enum GlobalSearchStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "GlobalSearch", bundle: .module)
    }

    static var title: String { text("globalSearch.title", "Search All Windows") }
    static var placeholder: String { text("globalSearch.searchPlaceholder", "Search terminals, agent sessions and tabs") }
    static var prompt: String { text("globalSearch.prompt", "Type to search every terminal, agent session and tab") }
    static var show: String { text("globalSearch.show", "Show") }
    static var copyLine: String { text("globalSearch.copyLine", "Copy Line") }
    static var noMatches: String { text("globalSearch.noMatchesAnywhere", "No matches") }
    static var noTabs: String { text("globalSearch.noTabs", "No tabs to search") }
    static func limited(_ count: Int) -> String {
        String(format: text("globalSearch.limited", "First %lld matches"), count)
    }
    static func unreadable(_ count: Int) -> String {
        String(format: text("globalSearch.unreadable", "Terminals not read: %lld"), count)
    }
    static func matches(_ count: Int) -> String {
        String(format: text("globalSearch.matchCount", "%lld matches"), count)
    }
    static func agentName(_ harness: String) -> String {
        harness == "codex" ? "Codex" : "Claude"
    }
}
