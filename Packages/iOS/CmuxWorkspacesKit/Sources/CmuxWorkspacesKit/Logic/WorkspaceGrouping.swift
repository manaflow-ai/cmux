import Foundation

/// A titled run of workspaces, in display order.
public struct WorkspaceSection: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case pinned, needsYou, running, today, yesterday, previous7Days, older, other
    }

    public var kind: Kind
    public var title: String
    public var items: [WorkspaceItem]

    public var id: Kind { kind }

    public init(kind: Kind, title: String, items: [WorkspaceItem]) {
        self.kind = kind
        self.title = title
        self.items = items
    }
}

/// Filters for the home list: everything, one state, or one Mac.
public enum WorkspaceFilter: Hashable, Sendable {
    case all
    case needsYou
    case running
    case mac(String)

    public func includes(_ item: WorkspaceItem) -> Bool {
        switch self {
        case .all: true
        case .needsYou: item.status.needsUser
        case .running: item.status == .working
        case let .mac(id): item.macID == id
        }
    }
}

/// Pure grouping, filtering and search for the three home designs.
public struct WorkspaceGrouping: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// Pinned first, then calendar-day recents (the Claude and ChatGPT layout).
    public func byDate(_ items: [WorkspaceItem], filter: WorkspaceFilter = .all) -> [WorkspaceSection] {
        let matching = items.filter(filter.includes)
        let pinned = filter == .all ? newestFirst(matching.filter(\.isPinned)) : []
        let rest = newestFirst(matching.filter { !pinned.contains($0) })
        var buckets: [WorkspaceSection.Kind: [WorkspaceItem]] = [:]
        for item in rest { buckets[dateKind(item.lastActivity), default: []].append(item) }
        var sections: [WorkspaceSection] = []
        if !pinned.isEmpty { sections.append(.init(kind: .pinned, title: "Pinned", items: pinned)) }
        for kind in [WorkspaceSection.Kind.today, .yesterday, .previous7Days, .older] {
            if let items = buckets[kind], !items.isEmpty {
                sections.append(.init(kind: kind, title: title(kind), items: items))
            }
        }
        return sections
    }

    /// Triage order: what needs you, what is running, then everything else.
    public func byState(_ items: [WorkspaceItem]) -> [WorkspaceSection] {
        let needs = newestFirst(items.filter { $0.status.needsUser })
        let running = newestFirst(items.filter { $0.status == .working })
        let other = newestFirst(items.filter { !$0.status.needsUser && $0.status != .working })
        return [
            WorkspaceSection(kind: .needsYou, title: "Needs you", items: needs),
            WorkspaceSection(kind: .running, title: "Running", items: running),
            WorkspaceSection(kind: .other, title: "Everything else", items: other),
        ].filter { !$0.items.isEmpty }
    }

    /// Case-insensitive match on name, branch, Mac name and tab titles.
    public func search(_ items: [WorkspaceItem], query: String, macs: [WorkspaceMac]) -> [WorkspaceItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return newestFirst(items) }
        let macNames = Dictionary(uniqueKeysWithValues: macs.map { ($0.id, $0.name) })
        return newestFirst(items.filter { item in
            let fields = [item.name, item.branch, macNames[item.macID] ?? ""] + item.tabs.map(\.title)
            return fields.contains { $0.localizedCaseInsensitiveContains(q) }
        })
    }

    public func dateKind(_ date: Date) -> WorkspaceSection.Kind {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) else { return .older }
        if date >= startOfYesterday { return .yesterday }
        if date >= startOfWeek { return .previous7Days }
        return .older
    }

    /// "now", "4m", "3h", "2d", then a short date.
    public func shortAge(_ date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func newestFirst(_ items: [WorkspaceItem]) -> [WorkspaceItem] {
        items.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func title(_ kind: WorkspaceSection.Kind) -> String {
        switch kind {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 days"
        case .older: "Older"
        case .pinned: "Pinned"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .other: "Everything else"
        }
    }
}
