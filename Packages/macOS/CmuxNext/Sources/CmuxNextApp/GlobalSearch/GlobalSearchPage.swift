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
        let located: LocatedTab
        var place: String { "\(located.workspace.displayName) › \(located.tab.displayTitle)" }
    }

    /// Shows a tab and, given a needle, runs its terminal's Find for it.
    typealias Reveal = @MainActor (LocatedTab, _ needle: String?) -> Void

    static let pageID = "globalSearch.results"

    /// The page, reading `tabs` once as it opens; `query` is its starting text.
    static func page(query: String, tabs: [Tab], reveal: @escaping Reveal) -> PalettePageSpec {
        let sources = tabs.map(\.source)
        let corpus = CorpusHolder(Task { await GlobalSearchCorpus.load(sources) })
        let byTab = Dictionary(tabs.map { ($0.source.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        return PalettePageSpec(
            id: pageID, title: GlobalSearchStrings.title, placeholder: GlobalSearchStrings.placeholder, symbol: "magnifyingglass",
            providers: [], initialQuery: query,
            // The page is left: a read still running has no one to answer.
            onCancel: { corpus.release() },
            queryResults: { query in
                let words = GlobalSearchCorpus.words(query)
                guard !words.isEmpty else { return [notice(GlobalSearchStrings.prompt, id: "prompt")] }
                guard let task = corpus.task else { return [] }
                let loaded = await task.value
                let found = await loaded.hits(words)
                // The palette keeps a closed page until its next open: a chosen row lets the text go.
                return items(found.hits, limited: found.limited, unreadable: loaded.unreadable, words: words, byTab: byTab,
                             reveal: reveal, done: { corpus.release() })
            },
            filtersByQuery: false)
    }

    static func items(_ hits: [GlobalSearchCorpus.Hit], limited: Bool, unreadable: Int, words: [String],
                      byTab: [String: Tab], reveal: @escaping Reveal, done: @escaping @MainActor () -> Void) -> [PaletteItem] {
        var rows = hits.compactMap { hit in byTab[hit.tabID].map { item(hit, words: words, in: $0, reveal: reveal, done: done) } }
        if rows.isEmpty { rows.append(notice(GlobalSearchStrings.noMatches, id: "none")) }
        if limited { rows.append(notice(GlobalSearchStrings.limited(GlobalSearchCorpus.limit), id: "limited")) }
        if unreadable > 0 { rows.append(notice(GlobalSearchStrings.unreadable(unreadable), id: "unreadable")) }
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
            title: line.map { GlobalSearchCorpus.snippet($0, words: words) } ?? located.tab.displayTitle,
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

/// The page's text, until the page is left or a row is chosen.
@MainActor
final class CorpusHolder {
    private(set) var task: Task<GlobalSearchCorpus, Never>?

    init(_ task: Task<GlobalSearchCorpus, Never>) {
        self.task = task
    }

    /// Stops a read still running and drops the text.
    func release() {
        task?.cancel()
        task = nil
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
