public import Foundation

/// A filter over merged history entries: the history page's search field
/// and chips, `cmux history list|search`, the palette's history page.
public nonisolated struct HistoryQuery: Hashable, Sendable {
    public var text: String
    /// Empty means every kind.
    public var kinds: Set<HistoryEntry.Kind>
    public var range: HistoryRange
    public var limit: Int?

    public init(text: String = "", kinds: Set<HistoryEntry.Kind> = [], range: HistoryRange = .all, limit: Int? = nil) {
        self.text = text
        self.kinds = kinds
        self.range = range
        self.limit = limit
    }

    /// Entries that match, newest first. Every whitespace-separated token
    /// must appear in the entry's search text (case and diacritic
    /// insensitive), in any order.
    public func apply(to entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryEntry] {
        let tokens = Self.tokens(text)
        let interval = range.interval(now: now, calendar: calendar)
        var matched = entries.filter { entry in
            Self.isDisplayable(entry)
                && (kinds.isEmpty || kinds.contains(entry.kind))
                && (interval.map { $0.contains(entry.time) } ?? true)
                && Self.matches(entry.searchText, tokens)
        }
        matched.sort { ($0.time, $0.id) > ($1.time, $1.id) }
        if let limit, matched.count > limit { matched.removeLast(matched.count - limit) }
        return matched
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    static func matches(_ haystack: String, _ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let folded = fold(haystack)
        return tokens.allSatisfy { folded.contains($0) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Removes implementation locations and placeholder pages from the user
    /// history. App pages, blank tabs, and directory URLs are navigation
    /// machinery rather than destinations a person can return to.
    private static func isDisplayable(_ entry: HistoryEntry) -> Bool {
        switch entry.payload {
        case .page(let text, _):
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "file" else { return false }
            if url.isFileURL {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return false
                }
            }
            return true
        case .location(let location, _):
            if let url = location.url, let parsed = URL(string: url) {
                if parsed.scheme?.lowercased() == "cmux" || parsed.absoluteString.lowercased() == "about:blank" {
                    return false
                }
                if parsed.isFileURL {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: parsed.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        return false
                    }
                }
            }
            return location.title != "~"
        default:
            return true
        }
    }
}

/// A time range for filtering and clearing history.
public nonisolated enum HistoryRange: String, CaseIterable, Hashable, Sendable, Codable {
    case hour, today, week, month, all

    /// The interval ending `now`, or nil for all time.
    public func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .hour: DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(1))
        case .today: DateInterval(start: calendar.startOfDay(for: now), end: now.addingTimeInterval(1))
        case .week: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now.addingTimeInterval(1))
        case .month: DateInterval(start: now.addingTimeInterval(-28 * 86_400), end: now.addingTimeInterval(1))
        case .all: nil
        }
    }

    /// The earliest time the range covers (nil: all time).
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        interval(now: now, calendar: calendar)?.start
    }
}

/// Entries grouped for display, newest group first.
public nonisolated enum HistoryGrouping: String, CaseIterable, Hashable, Sendable {
    case day, workspace, machine

    public struct Group: Hashable, Sendable, Identifiable {
        public var id: String
        /// The day's start for `.day`, else the newest entry's time.
        public var date: Date
        /// The workspace or machine name; nil for `.day`.
        public var name: String?
        public var entries: [HistoryEntry]
    }

    /// Groups `entries` (already newest first) keeping their order inside
    /// each group; groups are ordered by their newest entry.
    public func groups(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [Group] {
        var order: [String] = []
        var byKey: [String: Group] = [:]
        for entry in entries {
            let (key, date, name) = keyed(entry, calendar: calendar)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(id: key, date: date, name: name, entries: [])
            }
            byKey[key]?.entries.append(entry)
        }
        return order.compactMap { byKey[$0] }
    }

    private func keyed(_ entry: HistoryEntry, calendar: Calendar) -> (String, Date, String?) {
        switch self {
        case .day:
            let day = calendar.startOfDay(for: entry.time)
            return ("day:\(Int(day.timeIntervalSince1970))", day, nil)
        case .workspace:
            let name = entry.workspaceName
            return ("workspace:\(name ?? "")", entry.time, name)
        case .machine:
            return ("machine:\(entry.machineName ?? "")", entry.time, entry.machineName)
        }
    }
}

nonisolated extension HistoryEntry {
    /// The workspace an entry belongs to, when it has one.
    public var workspaceName: String? {
        switch payload {
        case .location(let location, _): location.workspaceTitle ?? location.workspace
        case .closed(let item): item.workspace
        case .agent(let session): session.workspace
        case .page, .command: nil
        }
    }
}
