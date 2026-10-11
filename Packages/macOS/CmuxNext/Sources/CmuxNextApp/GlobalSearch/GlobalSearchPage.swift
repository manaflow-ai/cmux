import AppKit
import CmuxNextActions
import CmuxNextPalette

/// The matches of one Search All Windows query as a palette page: one row
/// per matching line, titled with the line and subtitled with where it is.
@MainActor
enum GlobalSearchPage {
    /// A searched terminal, as the rows show and reveal it.
    struct Terminal {
        let target: TerminalTextSearch.Target
        let located: LocatedTab
        var place: String { "\(located.workspace.displayName) › \(located.tab.displayTitle)" }
    }

    /// Shows a terminal and runs its find for `needle`.
    typealias Reveal = @MainActor (LocatedTab, _ needle: String) -> Void

    static func page(query: String, terminals: [Terminal], reveal: @escaping Reveal) -> PalettePageSpec {
        let words = TerminalTextSearch.words(query)
        let targets = terminals.map(\.target)
        let provider = AsyncPaletteProvider(id: "globalSearch.results") {
            items(for: await TerminalTextSearch.search(targets, words: words), words: words, terminals: terminals, reveal: reveal)
        }
        return PalettePageSpec(id: "globalSearch.results", title: query, placeholder: GlobalSearchStrings.placeholder,
                               symbol: "magnifyingglass", providers: [provider])
    }

    static func items(for results: TerminalTextSearch.Results, words: [String],
                      terminals: [Terminal], reveal: @escaping Reveal) -> [PaletteItem] {
        let byTab = Dictionary(terminals.map { ($0.target.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [PaletteItem] = []
        for (tabID, lines) in results.matches {
            guard let terminal = byTab[tabID] else { continue }
            for (index, line) in lines.enumerated() {
                rows.append(item(line, index: index, words: words, in: terminal, reveal: reveal))
            }
        }
        if rows.isEmpty { rows.append(notice(GlobalSearchStrings.noMatches, id: "none")) }
        if results.limited { rows.append(notice(GlobalSearchStrings.limited(TerminalTextSearch.limit), id: "limited")) }
        if results.unreadable > 0 { rows.append(notice(GlobalSearchStrings.unreadable(results.unreadable), id: "unreadable")) }
        return rows
    }

    /// The word Find highlights: the first query word, as typed in the line.
    static func needle(in line: String, words: [String]) -> String {
        guard let word = words.first else { return "" }
        guard let range = line.range(of: word, options: .caseInsensitive) else { return word }
        return String(line[range])
    }

    private static func item(_ line: String, index: Int, words: [String], in terminal: Terminal,
                             reveal: @escaping Reveal) -> PaletteItem {
        let located = terminal.located
        let needle = needle(in: line, words: words)
        return PaletteItem(
            id: "\(terminal.target.tabID):\(index)", title: line, subtitle: terminal.place,
            symbol: "terminal", keywords: [terminal.place],
            primary: PaletteCommand(id: "show", title: GlobalSearchStrings.showInTerminal, symbol: "return",
                                    effect: .perform { reveal(located, needle) }),
            secondary: [
                PaletteCommand(id: "copyLine", title: GlobalSearchStrings.copyLine, symbol: "doc.on.doc", effect: .perform {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                }),
            ])
    }

    private static func notice(_ text: String, id: String) -> PaletteItem {
        PaletteItem(id: "globalSearch.notice.\(id)", title: text, symbol: "info.circle", isEnabled: false, primary:
            PaletteCommand(id: "none", title: text, effect: .performKeepingOpen {}), rankBias: -1_000)
    }
}

enum GlobalSearchStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "GlobalSearch", bundle: .module)
    }

    static var placeholder: String { text("globalSearch.placeholder", "Filter matches") }
    static var showInTerminal: String { text("globalSearch.showInTerminal", "Show in Terminal") }
    static var copyLine: String { text("globalSearch.copyLine", "Copy Line") }
    static var noMatches: String { text("globalSearch.noMatches", "No matches in any terminal") }
    static var noTerminals: String { text("globalSearch.noTerminals", "No terminals to search") }
    static func limited(_ count: Int) -> String {
        String(format: text("globalSearch.limited", "First %lld matches"), count)
    }
    static func unreadable(_ count: Int) -> String {
        String(format: text("globalSearch.unreadable", "Terminals not read: %lld"), count)
    }
}
