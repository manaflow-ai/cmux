/// Picks the native New Tab page's dropdown rows for the typed text (``NativeNewTabRow``).
///
/// Pure and synchronous: it reads only the page's omnibar lists, so a keystroke
/// costs one pass over them and no I/O. Empty text lists where you can go (open
/// tabs, then workspaces). Typed text leads with what Return does for the selected
/// kind, then the open tabs, workspaces, visited pages and Commands palette actions
/// that match, best match first.
///
/// ```swift
/// let rows = NativeNewTabRanker().rows(for: "side", kind: .agent, omnibar: page.omnibar)
/// ```
public nonisolated struct NativeNewTabRanker: Sendable {
    /// The most rows the dropdown shows.
    public var limit: Int
    /// The most open tabs and workspaces the empty field lists.
    public var emptyLimit: Int

    /// Creates a ranker.
    /// - Parameters:
    ///   - limit: The most rows the dropdown shows (9, as the web page).
    ///   - emptyLimit: The most rows the empty field lists.
    public init(limit: Int = 9, emptyLimit: Int = 6) {
        self.limit = limit
        self.emptyLimit = emptyLimit
    }

    /// The rows for `text` typed with `kind` selected. With `sources`, the chats the text finds and
    /// the agent starts it asks for list too (the web page's sections): an agent named with a folder
    /// ("codex cmux") leads above Ask while no tab or workspace has the text's exact name; else the
    /// rows go open tabs and workspaces, chats, starts, then pages and actions, each section keeping
    /// a row while the limit lets it.
    public func rows(for text: String, kind: AgentPaneTabKind, omnibar: AgentPaneOmnibar,
                     sources: NativeNewTabSources = NativeNewTabSources(agents: [])) -> [NativeNewTabRow] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let places = omnibar.tabs.map(NativeNewTabRow.tab) + omnibar.workspaces.map(NativeNewTabRow.workspace)
            return Array(places.prefix(emptyLimit))
        }
        let lead: NativeNewTabRow = switch kind {
        case .agent: .ask(query)
        case .terminal: .run(query)
        case .browser: .open(query)
        }
        var scored: [(row: NativeNewTabRow, score: Double, order: Int)] = []
        func add(_ row: NativeNewTabRow, weight: Double, _ texts: [String?]) {
            let score = Self.score(query, texts)
            if score > 0 { scored.append((row, Double(score) + weight, scored.count)) }
        }
        for tab in omnibar.tabs { add(.tab(tab), weight: 0.6, [tab.title, tab.detail, tab.workspace]) }
        for workspace in omnibar.workspaces { add(.workspace(workspace), weight: 0.5, [workspace.name, workspace.detail]) }
        for page in omnibar.history { add(.page(page), weight: kind == .browser ? 0.4 : 0.1, [page.title, page.url]) }
        for action in omnibar.actions { add(.action(action), weight: 0.3, [action.title] + action.keywords) }
        let ranked = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.row)
        let chats = sources.chatRows(query).map(NativeNewTabRow.chat)
        var starts = sources.startRows(query)
        // An exact tab or workspace name keeps Return ("codex" the workspace, not Codex's start).
        let needle = query.lowercased()
        let exactName = omnibar.workspaces.contains { $0.name.lowercased() == needle } || omnibar.tabs.contains { $0.title.lowercased() == needle }
        if kind != .agent || exactName { starts.named = false }
        let named = starts.named ? starts.rows.map(NativeNewTabRow.start) : []
        let unnamed = starts.named ? [] : starts.rows.prefix(NativeNewTabSources.maximumUnnamedStarts).map(NativeNewTabRow.start)
        let isPlace = { (row: NativeNewTabRow) -> Bool in
            switch row {
            case .tab, .workspace: true
            default: false
            }
        }
        let room = max(0, limit - 1 - named.count)
        // No chat and no start: the matches in their score order, as before the agent rows.
        guard !chats.isEmpty || !unnamed.isEmpty else { return named + [lead] + ranked.prefix(room) }
        let rest = Self.share([ranked.filter(isPlace), chats, Array(unnamed), ranked.filter { !isPlace($0) }], room: room)
        return named + [lead] + rest
    }

    /// Up to `room` rows from `sections`, taken one per section in turn, listed section by section.
    static func share(_ sections: [[NativeNewTabRow]], room: Int) -> [NativeNewTabRow] {
        var counts = Array(repeating: 0, count: sections.count)
        var taken = 0
        var more = true
        while more, taken < room {
            more = false
            for index in sections.indices where taken < room && counts[index] < sections[index].count {
                counts[index] += 1
                taken += 1
                more = true
            }
        }
        return sections.indices.flatMap { sections[$0].prefix(counts[$0]) }
    }

    /// How well `query` matches one of `texts`: 3 for a prefix, 2 for a word start, 1 for a
    /// match inside a word (3+ characters only), 0 for none. The web page's `matchScore`.
    static func score(_ query: String, _ texts: [String?]) -> Int {
        let needle = query.lowercased()
        var best = 0
        for case let text? in texts {
            let hay = text.lowercased()
            guard let range = hay.range(of: needle) else { continue }
            if range.lowerBound == hay.startIndex { return 3 }
            let before = hay[hay.index(before: range.lowerBound)]
            if " /._:@#-".contains(before) { best = max(best, 2) } else if needle.count >= 3 { best = max(best, 1) }
        }
        return best
    }
}
