import Foundation

/// The dimension the History timeline is grouped by. Date is the flagship
/// (browser-history-style buckets, "Last 24 hours" first); every other key
/// falls out of the same pure grouping pass over the event list.
enum VaultHistoryGroupKey: String, CaseIterable, Identifiable, Codable {
    case date
    case workspace
    case window
    case directory
    case agent
    case kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return String(localized: "vaultHistory.group.date", defaultValue: "Date")
        case .workspace: return String(localized: "vaultHistory.group.workspace", defaultValue: "Workspace")
        case .window: return String(localized: "vaultHistory.group.window", defaultValue: "Window")
        case .directory: return String(localized: "vaultHistory.group.directory", defaultValue: "Directory")
        case .agent: return String(localized: "vaultHistory.group.agent", defaultValue: "Agent")
        case .kind: return String(localized: "vaultHistory.group.kind", defaultValue: "Type")
        }
    }

    var symbolName: String {
        switch self {
        case .date: return "clock"
        case .workspace: return "square.on.square"
        case .window: return "macwindow"
        case .directory: return "folder"
        case .agent: return "person.2"
        case .kind: return "tag"
        }
    }
}

/// Browser-history-style date buckets, newest bucket first.
enum VaultHistoryDateBucket: Int, CaseIterable, Identifiable, Sendable {
    case last24Hours
    case yesterday
    case thisWeek
    case thisMonth
    case older

    var id: Int { rawValue }

    /// Buckets a timestamp relative to `now`. "Last 24 hours" is a rolling
    /// window (also absorbing any same-day stragglers, e.g. across a DST
    /// fold); the calendar buckets catch everything older, so an event from
    /// yesterday morning can land in `yesterday` while one from yesterday
    /// evening is still inside `last24Hours`.
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> VaultHistoryDateBucket {
        if date >= now.addingTimeInterval(-24 * 60 * 60) || calendar.isDate(date, inSameDayAs: now) {
            return .last24Hours
        }
        if isYesterday(date, now: now, calendar: calendar) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return .thisMonth
        }
        return .older
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    var label: String {
        switch self {
        case .last24Hours:
            return String(localized: "vaultHistory.bucket.last24Hours", defaultValue: "Last 24 hours")
        case .yesterday:
            return String(localized: "vaultHistory.bucket.yesterday", defaultValue: "Yesterday")
        case .thisWeek:
            return String(localized: "vaultHistory.bucket.thisWeek", defaultValue: "This week")
        case .thisMonth:
            return String(localized: "vaultHistory.bucket.thisMonth", defaultValue: "This month")
        case .older:
            return String(localized: "vaultHistory.bucket.older", defaultValue: "Older")
        }
    }
}

/// One rendered section of the History timeline: a stable identity, a
/// header title, and the section's events sorted newest first.
struct VaultHistoryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let events: [VaultHistoryEvent]
}

/// Pure grouping over a flat event list. Given the same events, key, `now`,
/// and calendar, the output is deterministic, with no clock or store access,
/// so every grouping behavior is unit-testable.
struct VaultHistoryGrouper: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    static let otherGroupID = "other"

    func groups(
        events: [VaultHistoryEvent],
        by key: VaultHistoryGroupKey,
        query: VaultHistoryQuery = VaultHistoryQuery(),
        now: Date
    ) -> [VaultHistoryGroup] {
        let sorted = query.visibleEvents(from: events, now: now)
        switch key {
        case .date:
            return dateGroups(
                sortedEvents: sorted,
                now: now,
                sortOrder: query.sortOrder
            )
        case .workspace:
            return subjectGroups(sortedEvents: sorted, idFor: { event in
                event.subject.workspaceId.map { "workspace:\($0.uuidString)" }
            }, sortOrder: query.sortOrder)
        case .window:
            return subjectGroups(sortedEvents: sorted, idFor: { event in
                event.subject.windowId.map { "window:\($0.uuidString)" }
            }, sortOrder: query.sortOrder)
        case .directory:
            return directoryGroups(sortedEvents: sorted, sortOrder: query.sortOrder)
        case .agent:
            return agentGroups(sortedEvents: sorted, sortOrder: query.sortOrder)
        case .kind:
            return kindGroups(sortedEvents: sorted, sortOrder: query.sortOrder)
        }
    }
    private func dateGroups(
        sortedEvents: [VaultHistoryEvent],
        now: Date,
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        var byBucket: [VaultHistoryDateBucket: [VaultHistoryEvent]] = [:]
        for event in sortedEvents {
            let bucket = VaultHistoryDateBucket.bucket(for: event.timestamp, now: now, calendar: calendar)
            byBucket[bucket, default: []].append(event)
        }
        let bucketOrder = sortOrder == .oldestFirst
            ? Array(VaultHistoryDateBucket.allCases.reversed())
            : VaultHistoryDateBucket.allCases
        return bucketOrder.compactMap { bucket in
            guard let events = byBucket[bucket], !events.isEmpty else { return nil }
            return VaultHistoryGroup(id: "date:\(bucket.rawValue)", title: bucket.label, events: events)
        }
    }
    /// Groups by an identity extracted from the subject. Group order follows
    /// each group's most recent event; events without the identity land in a
    /// trailing "Other" group. The group title is the newest event's title,
    /// so renamed workspaces show their latest name.
    private func subjectGroups(
        sortedEvents: [VaultHistoryEvent],
        idFor: (VaultHistoryEvent) -> String?,
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        var order: [String] = []
        var byId: [String: [VaultHistoryEvent]] = [:]
        for event in sortedEvents {
            let id = idFor(event) ?? Self.otherGroupID
            if byId[id] == nil { order.append(id) }
            byId[id, default: []].append(event)
        }
        if let otherIndex = order.firstIndex(of: Self.otherGroupID), otherIndex != order.count - 1 {
            order.remove(at: otherIndex)
            order.append(Self.otherGroupID)
        }
        let groups = order.compactMap { id -> VaultHistoryGroup? in
            guard let events = byId[id], !events.isEmpty else { return nil }
            let title = id == Self.otherGroupID
                ? String(localized: "vaultHistory.group.other", defaultValue: "Other")
                : (latestNonemptyTitle(in: events)
                    ?? String(localized: "vaultHistory.untitled", defaultValue: "Untitled"))
            return VaultHistoryGroup(id: id, title: title, events: events)
        }
        return titleSortedIfNeeded(groups, sortOrder: sortOrder)
    }
    private func directoryGroups(
        sortedEvents: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        var order: [String] = []
        var byDirectory: [String: [VaultHistoryEvent]] = [:]
        for event in sortedEvents {
            let directory = Self.normalizedDirectory(event.subject.directory)
            let id = directory.map { "directory:\($0)" } ?? Self.otherGroupID
            if byDirectory[id] == nil { order.append(id) }
            byDirectory[id, default: []].append(event)
        }
        moveOtherGroupToEnd(&order)
        let groups = order.compactMap { id -> VaultHistoryGroup? in
            guard let events = byDirectory[id], !events.isEmpty else { return nil }
            let title = id == Self.otherGroupID
                ? String(localized: "vaultHistory.group.unknownDirectory", defaultValue: "Unknown directory")
                : String(id.dropFirst("directory:".count))
            return VaultHistoryGroup(id: id, title: title, events: events)
        }
        return titleSortedIfNeeded(groups, sortOrder: sortOrder)
    }

    private func agentGroups(
        sortedEvents: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        var order: [String] = []
        var byId: [String: [VaultHistoryEvent]] = [:]
        for event in sortedEvents {
            let id = event.subject.agent.map { "agent:\($0)" } ?? Self.otherGroupID
            if byId[id] == nil { order.append(id) }
            byId[id, default: []].append(event)
        }
        if let otherIndex = order.firstIndex(of: Self.otherGroupID), otherIndex != order.count - 1 {
            order.remove(at: otherIndex)
            order.append(Self.otherGroupID)
        }
        let groups = order.compactMap { id -> VaultHistoryGroup? in
            guard let events = byId[id], !events.isEmpty else { return nil }
            let title: String
            if id == Self.otherGroupID {
                title = String(localized: "vaultHistory.group.cmux", defaultValue: "cmux")
            } else if let displayName = events.first?.subject.agentDisplayName,
                      !displayName.isEmpty {
                title = displayName
            } else if let raw = events.first?.subject.agent, let agent = SessionAgent(rawValue: raw) {
                title = agent.displayName
            } else {
                title = String(localized: "vaultHistory.group.other", defaultValue: "Other")
            }
            return VaultHistoryGroup(id: id, title: title, events: events)
        }
        return titleSortedIfNeeded(groups, sortOrder: sortOrder)
    }

    private func kindGroups(
        sortedEvents: [VaultHistoryEvent],
        sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        var order: [VaultHistoryEventKind] = []
        var byKind: [VaultHistoryEventKind: [VaultHistoryEvent]] = [:]
        for event in sortedEvents {
            if byKind[event.kind] == nil { order.append(event.kind) }
            byKind[event.kind, default: []].append(event)
        }
        let groups = order.compactMap { kind -> VaultHistoryGroup? in
            guard let events = byKind[kind], !events.isEmpty else { return nil }
            return VaultHistoryGroup(id: "kind:\(kind.rawValue)", title: kind.label, events: events)
        }
        return titleSortedIfNeeded(groups, sortOrder: sortOrder)
    }

    private func latestNonemptyTitle(in events: [VaultHistoryEvent]) -> String? {
        events
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id < $1.id
            }?
            .title
    }

    private func titleSortedIfNeeded(
        _ groups: [VaultHistoryGroup], sortOrder: VaultHistoryQuery.SortOrder
    ) -> [VaultHistoryGroup] {
        guard sortOrder == .titleAscending else { return groups }
        return groups.sorted { lhs, rhs in
            if lhs.id == Self.otherGroupID { return false }
            if rhs.id == Self.otherGroupID { return true }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func moveOtherGroupToEnd(_ order: inout [String]) {
        guard let otherIndex = order.firstIndex(of: Self.otherGroupID),
              otherIndex != order.count - 1 else {
            return
        }
        order.remove(at: otherIndex)
        order.append(Self.otherGroupID)
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        let standardized = (trimmed as NSString).standardizingPath
        return standardized.isEmpty || standardized == "." ? nil : standardized
    }
}
