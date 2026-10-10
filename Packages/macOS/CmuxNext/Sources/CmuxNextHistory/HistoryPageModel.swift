public import Foundation
public import Observation

/// What the `cmux://history` page needs from the App (history.md 5.1).
public protocol HistoryPageSource: AnyObject {
    func entries(_ query: HistoryQuery) async -> [HistoryEntry]
    func open(_ entry: HistoryEntry, newTab: Bool)
    func remove(_ entry: HistoryEntry)
    func removeSite(of entry: HistoryEntry)
    func clear(range: HistoryRange)
    func copy(_ text: String)
}

/// The page's state: query, filter, grouping, loaded groups. Reloads are
/// generation-numbered, so a slow older load never replaces a newer one.
@Observable
public final class HistoryPageModel {
    public enum Filter: String, CaseIterable, Hashable, Sendable {
        case all, pages, locations, commands, agents, closed

        public var kinds: Set<HistoryEntry.Kind> {
            switch self {
            case .all: []
            case .pages: [.page]
            case .locations: [.location]
            case .commands: [.command]
            case .agents: [.agent]
            case .closed: [.closed]
            }
        }
    }

    public var text = "" { didSet { if text != oldValue { reload() } } }
    public var filter: Filter = .all { didSet { if filter != oldValue { reload() } } }
    public var grouping: HistoryGrouping = .day { didSet { regroup() } }
    public private(set) var groups: [HistoryGrouping.Group] = []
    public private(set) var isLoading = false
    public var selection: String?

    @ObservationIgnored public weak var source: (any HistoryPageSource)?
    @ObservationIgnored private var entries: [HistoryEntry] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored public var calendar = Calendar.current
    public static let limit = 1_000

    public init(source: (any HistoryPageSource)? = nil) {
        self.source = source
    }

    public func reload() {
        generation += 1
        let current = generation
        let query = HistoryQuery(text: text, kinds: filter.kinds, limit: Self.limit)
        loading?.cancel()
        isLoading = true
        loading = Task { [weak self] in
            let loaded = await self?.source?.entries(query) ?? []
            guard let self, current == generation else { return }
            apply(loaded)
        }
    }

    /// Installs loaded entries (tests call it directly).
    public func apply(_ loaded: [HistoryEntry]) {
        entries = loaded
        isLoading = false
        regroup()
        if let selection, !loaded.contains(where: { $0.id == selection }) { self.selection = loaded.first?.id }
    }

    private func regroup() {
        groups = grouping.groups(entries, calendar: calendar)
    }

    public var flatEntries: [HistoryEntry] { groups.flatMap(\.entries) }

    public func entry(id: String?) -> HistoryEntry? {
        id.flatMap { id in entries.first { $0.id == id } }
    }

    /// Moves the selection by `offset` rows (arrow keys).
    public func moveSelection(_ offset: Int) {
        let flat = flatEntries
        guard !flat.isEmpty else { return }
        let index = flat.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : flat.count)
        selection = flat[max(0, min(flat.count - 1, index + offset))].id
    }

    public func open(_ entry: HistoryEntry, newTab: Bool = false) { source?.open(entry, newTab: newTab) }

    public func remove(_ entry: HistoryEntry) {
        source?.remove(entry)
        apply(entries.filter { $0.id != entry.id })
    }

    public func removeSite(of entry: HistoryEntry) {
        source?.removeSite(of: entry)
        reload()
    }

    public func clear(_ range: HistoryRange) {
        source?.clear(range: range)
        reload()
    }

    public func copy(_ text: String) { source?.copy(text) }
}

/// The page's address.
public nonisolated enum HistoryPageAddress {
    public static let string = "cmux://history"
    /// The page address (a literal a test parses; /dev/null stands in rather than a trap).
    public static let url: URL = URL(string: string) ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://history`, with or without a trailing slash, query or fragment.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "history"
    }
}
