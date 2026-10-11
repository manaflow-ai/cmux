public import Foundation

/// One row of Search Tabs before it becomes a palette item: its section,
/// the text it shows and the text it matches. Pure data.
public nonisolated struct TabSearchRow: Sendable, Hashable {
    public var entry: TabSearchEntry
    public var section: TabSearchSection
    public var title: String
    public var subtitle: String?
    public var accessory: String?
    /// Matched after the title: URL, full directory, process, workspace,
    /// machine and kind.
    public var keywords: [String]
    /// Ranking boost for a typed query: recent tabs win ties.
    public var rankBias: Int
    /// Listed before the user types (older closed tabs only match a query).
    public var isVisibleWhenQueryEmpty: Bool
}

/// A titled group of Search Tabs rows. `order` keeps open tabs above closed
/// ones for every query (`PalettePageSpec.keepsSectionOrder`).
public nonisolated struct TabSearchSection: Sendable, Hashable {
    public var id: String
    public var title: String
    public var order: Int

    public static let closedOrder = 1_000_000
}

/// Builds the Search Tabs rows from entries (pure; the provider, the
/// control method and the tests share it).
///
/// Open tabs come first. `recent` and `compact` list them by last use with
/// the current tab on top (the page then selects the second row, so Return
/// switches back to the previous tab); `grouped` lists them by window and
/// workspace in layout order. Recently closed tabs follow, newest first:
/// `closedListed` of them before the user types, up to `closedSearchable`
/// for a query.
public nonisolated enum TabSearchPlan {
    public static let closedListed = 10
    public static let closedListedCompact = 5
    public static let closedSearchable = 50
    /// Ranking boost of the most recently used tab; each older tab gets
    /// `recencyStep` less, down to zero.
    public static let recencyBoost = 16
    public static let recencyStep = 2

    public static func rows(_ entries: [TabSearchEntry], style: TabSearchStyle, now: Date) -> [TabSearchRow] {
        // Ids are unique per kind of row; a repeat (two machines reusing an
        // id) keeps its first entry rather than listing a row twice.
        var seenOpen = Set<String>()
        var seenClosed = Set<String>()
        let open = entries.filter { !$0.isClosed && seenOpen.insert($0.id).inserted }
        let closed = entries.filter { $0.isClosed && seenClosed.insert($0.id).inserted }.sorted(by: newestFirst).prefix(closedSearchable)
        var rows: [TabSearchRow] = []
        let byRecency = open.sorted(by: mostRecentFirst)
        let rankOf = Dictionary(byRecency.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let openSection = TabSearchSection(id: "tabSearch.open", title: PaletteStrings.tabSearchOpenSection, order: 0)
        switch style {
        case .recent, .compact:
            for entry in byRecency {
                rows.append(row(entry, section: openSection, style: style, rank: rankOf[entry.id] ?? 0, now: now))
            }
        case .grouped:
            var groupOrder: [String: Int] = [:]
            for entry in open.sorted(by: { $0.order < $1.order }) {
                let key = groupKey(entry)
                let order = groupOrder[key] ?? {
                    let next = groupOrder.count
                    groupOrder[key] = next
                    return next
                }()
                let section = TabSearchSection(id: "tabSearch.group.\(key)", title: groupTitle(entry), order: order)
                rows.append(row(entry, section: section, style: style, rank: rankOf[entry.id] ?? 0, now: now))
            }
        }
        let closedSection = TabSearchSection(id: "tabSearch.closed", title: PaletteStrings.tabSearchClosedSection,
                                             order: TabSearchSection.closedOrder)
        let listed = style == .compact ? closedListedCompact : closedListed
        for (index, entry) in closed.enumerated() {
            var closedRow = row(entry, section: closedSection, style: style, rank: index, now: now)
            closedRow.rankBias = 0
            closedRow.isVisibleWhenQueryEmpty = index < listed
            rows.append(closedRow)
        }
        return rows
    }

    /// The row the page selects before the user types: the second one when
    /// the first is the current tab and another open tab follows.
    public static func emptyQuerySelection(_ rows: [TabSearchRow]) -> Int {
        let open = rows.filter { !$0.entry.isClosed }
        guard open.count > 1, rows.first?.entry.isCurrent == true else { return 0 }
        return 1
    }

    // MARK: Ordering

    static func mostRecentFirst(_ lhs: TabSearchEntry, _ rhs: TabSearchEntry) -> Bool {
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        switch (lhs.lastUsed, rhs.lastUsed) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.order < rhs.order
        }
    }

    static func newestFirst(_ lhs: TabSearchEntry, _ rhs: TabSearchEntry) -> Bool {
        let l = lhs.lastUsed ?? .distantPast
        let r = rhs.lastUsed ?? .distantPast
        return l != r ? l > r : lhs.order < rhs.order
    }

    // MARK: Row text

    static func row(_ entry: TabSearchEntry, section: TabSearchSection, style: TabSearchStyle, rank: Int, now: Date) -> TabSearchRow {
        let place = placeText(entry, short: style == .compact)
        var subtitleParts: [String] = []
        if let place { subtitleParts.append(place) }
        if style == .recent, let workspace = entry.workspaceTitle, !workspace.isEmpty { subtitleParts.append(workspace) }
        if style != .compact {
            if let machine = entry.machine { subtitleParts.append(machine) }
            if style == .recent, let window = entry.windowTitle { subtitleParts.append(window) }
        }
        let accessory: String? = switch entry.state {
        case .open(true, _): PaletteStrings.current
        case .open: style == .compact ? nil : entry.process
        case .closed(let closedAt): relative(closedAt, now: now)
        }
        var keywords: [String] = []
        if let url = entry.url { keywords.append(url) }
        if let cwd = entry.cwd { keywords.append(cwd) }
        if let process = entry.process { keywords.append(process) }
        if let workspace = entry.workspaceTitle { keywords.append(workspace) }
        if let machine = entry.machine { keywords.append(machine) }
        keywords.append(kindWord(entry.kind))
        return TabSearchRow(
            entry: entry, section: section, title: entry.title.isEmpty ? PaletteStrings.tabSearchUntitled : entry.title,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "), accessory: accessory,
            keywords: keywords, rankBias: max(0, recencyBoost - recencyStep * rank), isVisibleWhenQueryEmpty: true)
    }

    /// The site of a page or the folder of a terminal: `github.com`,
    /// `~/src/api` (`api` when short).
    static func placeText(_ entry: TabSearchEntry, short: Bool) -> String? {
        if let host = entry.host { return host }
        if let url = entry.url, !url.isEmpty { return url }
        guard let cwd = entry.cwd, !cwd.isEmpty else { return nil }
        if short {
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? cwd : name
        }
        return abbreviatePath(cwd)
    }

    static func groupKey(_ entry: TabSearchEntry) -> String {
        "\(entry.windowTitle ?? "")|\(entry.machine ?? "")|\(entry.workspaceID ?? "")"
    }

    static func groupTitle(_ entry: TabSearchEntry) -> String {
        let workspace = entry.workspaceTitle.flatMap { $0.isEmpty ? nil : $0 } ?? PaletteStrings.tabSearchUntitled
        return [entry.windowTitle, workspace, entry.machine].compactMap { $0 }.joined(separator: " · ")
    }

    static func kindWord(_ kind: TabSearchEntry.Kind) -> String {
        switch kind {
        case .terminal, .remoteTerminal: PaletteStrings.tabSearchKindTerminal
        case .browser: PaletteStrings.tabSearchKindBrowser
        case .other: PaletteStrings.tabKeyword
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        // "now" for a tab closed this second, never "in 0s".
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
