import CmuxNextActions
import Foundation

/// The groups, panes and tabs of Go to Workspace (Cmd-P): every place the
/// user can go besides a workspace, each row with its kind (icon and label)
/// and its parent workspace and group. They show once the user types.
public final class NavigationPaletteProvider: PaletteProvider {
    public let id = "navigation"
    public let showsItemsForEmptyQuery: Bool
    private weak var source: (any PaletteNavigationSource)?

    public init(source: any PaletteNavigationSource, showsItemsForEmptyQuery: Bool = false) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var groupSection: PaletteSection {
        PaletteSection(id: "groups", title: PaletteStrings.sectionGroups, order: 12)
    }

    public static var paneSection: PaletteSection {
        PaletteSection(id: "panes", title: PaletteStrings.sectionPanes, order: 15)
    }

    public var immediateItems: [PaletteItem]? {
        guard let source else { return [] }
        return Self.items(source.navigationEntries(), source: source)
    }

    public func items() async -> [PaletteItem] { immediateItems ?? [] }

    /// Panes and tabs rank a little below a workspace with the same match;
    /// recency (below) lifts them back.
    static let paneBias = -4
    static let tabBias = -2

    /// The rows of `entries` (pure; the tests call it). The most recently
    /// used tabs and panes get a recency boost that shrinks by rank, as in
    /// Search Tabs, so of two equal matches the recent one goes first.
    @MainActor
    static func items(_ entries: [PaletteNavigationEntry], source: (any PaletteNavigationSource)?) -> [PaletteItem] {
        let recency = recencyRanks(entries)
        return entries.map { entry in
            let boost = recency[entry.itemID].map { max(0, TabSearchPlan.recencyBoost - TabSearchPlan.recencyStep * $0) } ?? 0
            return item(entry, recencyBoost: boost, source: source)
        }
    }

    /// Rank by last use, newest first, of the entries that were ever used.
    static func recencyRanks(_ entries: [PaletteNavigationEntry]) -> [String: Int] {
        let used = entries.compactMap { entry in entry.lastUsed.map { (entry.itemID, $0) } }
            .sorted { $0.1 > $1.1 }
        var ranks: [String: Int] = [:]
        for (rank, pair) in used.enumerated() where ranks[pair.0] == nil { ranks[pair.0] = rank }
        return ranks
    }

    @MainActor
    static func item(_ entry: PaletteNavigationEntry, recencyBoost: Int, source: (any PaletteNavigationSource)?) -> PaletteItem {
        let open = PaletteCommand(id: "select", title: commandTitle(entry.kind), symbol: "return", effect: .perform { [weak source] in
            source?.open(entry)
        })
        let parents = [entry.workspaceTitle, entry.groupTitle].compactMap { $0?.isEmpty == false ? $0 : nil }
        var item: PaletteItem
        switch entry.kind {
        case .group(let count):
            item = PaletteItem(
                id: entry.itemID, title: entry.title, subtitle: PaletteStrings.groupWorkspaceCount(count),
                accessory: PaletteStrings.kindGroup, symbol: "folder", section: groupSection,
                keywords: [PaletteStrings.groupKeyword] + entry.keywords, primary: open, frecencyKey: entry.itemID)
            item.ball = entry.color.map(PaletteBall.init)
        case .pane:
            item = PaletteItem(
                id: entry.itemID, title: entry.title.isEmpty ? PaletteStrings.kindPane : entry.title,
                subtitle: parents.isEmpty ? nil : parents.joined(separator: " · "),
                accessory: entry.isCurrent ? PaletteStrings.current : PaletteStrings.kindPane,
                symbol: "rectangle.split.2x1", section: paneSection,
                keywords: [PaletteStrings.paneKeyword] + entry.keywords, primary: open, frecencyKey: entry.itemID,
                rankBias: paneBias + recencyBoost)
            item.actionRefs = [PaletteActionRef("pane.focus", target: ActionTargetRef(kind: .pane, id: entry.id), title: open.title)]
        case .tab(let kind):
            let parts = parents + [entry.url.flatMap(host) ?? entry.cwd.map(abbreviatePath)].compactMap { $0 }
            item = PaletteItem(
                id: entry.itemID, title: entry.title.isEmpty ? PaletteStrings.tabSearchUntitled : entry.title,
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                accessory: entry.isCurrent ? PaletteStrings.current : kindLabel(kind),
                symbol: symbol(kind), brand: entry.agent, section: TabPaletteProvider.section,
                keywords: [PaletteStrings.tabKeyword, entry.url, entry.cwd, entry.agent].compactMap { $0 } + sessionWords(entry.sessionID)
                    + entry.keywords,
                primary: open, secondary: copySession(entry.sessionID), frecencyKey: entry.itemID, rankBias: tabBias + recencyBoost)
            item.actionRefs = [PaletteActionRef("tab.focus", target: ActionTargetRef(kind: .tab, id: entry.id), title: open.title)]
        }
        return item
    }

    /// A session id and, for an `acp:` handle, the bare id: either finds the row.
    static func sessionWords(_ id: String?) -> [String] {
        guard let id else { return [] }
        let prefix = PaletteNavigationEntry.acpPrefix
        if id.hasPrefix(prefix) { return [id, String(id.dropFirst(prefix.count))] }
        return [id]
    }

    /// Copy Session ID (the Actions menu, Cmd-K), for a row with a session.
    static func copySession(_ id: String?) -> [PaletteCommand] {
        guard let id else { return [] }
        return [PaletteCommand(id: "copySessionID", title: PaletteStrings.copySessionID, symbol: "doc.on.doc", effect: .perform {
            PaletteClipboard.copy(id)
        })]
    }

    private static func commandTitle(_ kind: PaletteNavigationEntry.Kind) -> String {
        switch kind {
        case .group: PaletteStrings.goToGroup
        case .pane: PaletteStrings.focusPane
        case .tab: PaletteStrings.switchToTab
        }
    }

    static func symbol(_ kind: PaletteNavigationEntry.TabKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .browser: "globe"
        case .remoteTerminal: "network"
        case .agentChat: "bubble.left.and.text.bubble.right"
        case .markdown: "doc.richtext"
        case .file: "doc.text"
        case .page: "doc"
        case .other: "square.dashed"
        }
    }

    static func kindLabel(_ kind: PaletteNavigationEntry.TabKind) -> String {
        switch kind {
        case .terminal: PaletteStrings.kindTerminal
        case .browser: PaletteStrings.kindBrowser
        case .remoteTerminal: PaletteStrings.kindRemoteTerminal
        case .agentChat: PaletteStrings.kindAgentChat
        case .markdown: PaletteStrings.kindMarkdown
        case .file: PaletteStrings.kindFile
        case .page: PaletteStrings.kindPage
        case .other: PaletteStrings.kindTab
        }
    }

    /// The URL's host without `www.`, else nil.
    private static func host(_ url: String) -> String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
