import Foundation

/// User-selected filtering and ordering for the History timeline.
struct VaultHistoryQuery: Equatable, Sendable {
    enum TimeRange: String, CaseIterable, Identifiable, Codable, Sendable {
        case allTime
        case last24Hours
        case last7Days
        case last30Days

        var id: String { rawValue }

        var label: String {
            switch self {
            case .allTime:
                return String(localized: "vaultHistory.range.allTime", defaultValue: "All time")
            case .last24Hours:
                return String(localized: "vaultHistory.range.last24Hours", defaultValue: "Last 24 hours")
            case .last7Days:
                return String(localized: "vaultHistory.range.last7Days", defaultValue: "Last 7 days")
            case .last30Days:
                return String(localized: "vaultHistory.range.last30Days", defaultValue: "Last 30 days")
            }
        }

        var symbolName: String {
            switch self {
            case .allTime: return "calendar"
            case .last24Hours: return "clock"
            case .last7Days: return "calendar.day.timeline.leading"
            case .last30Days: return "calendar.badge.clock"
            }
        }

        func includes(_ timestamp: Date, relativeTo now: Date) -> Bool {
            switch self {
            case .allTime:
                return true
            case .last24Hours:
                return timestamp >= now.addingTimeInterval(-24 * 60 * 60)
            case .last7Days:
                return timestamp >= now.addingTimeInterval(-7 * 24 * 60 * 60)
            case .last30Days:
                return timestamp >= now.addingTimeInterval(-30 * 24 * 60 * 60)
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
        case newestFirst
        case oldestFirst
        case titleAscending

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newestFirst:
                return String(localized: "vaultHistory.sort.newestFirst", defaultValue: "Newest first")
            case .oldestFirst:
                return String(localized: "vaultHistory.sort.oldestFirst", defaultValue: "Oldest first")
            case .titleAscending:
                return String(localized: "vaultHistory.sort.titleAscending", defaultValue: "Title A–Z")
            }
        }

        var symbolName: String {
            switch self {
            case .newestFirst: return "arrow.down"
            case .oldestFirst: return "arrow.up"
            case .titleAscending: return "textformat.abc"
            }
        }
    }

    var timeRange: TimeRange
    var sortOrder: SortOrder
    var searchText: String

    init(
        timeRange: TimeRange = .allTime,
        sortOrder: SortOrder = .newestFirst,
        searchText: String = ""
    ) {
        self.timeRange = timeRange
        self.sortOrder = sortOrder
        self.searchText = searchText
    }

    func visibleEvents(from events: [VaultHistoryEvent], now: Date) -> [VaultHistoryEvent] {
        let tokens = searchText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return events
            .filter { timeRange.includes($0.timestamp, relativeTo: now) }
            .filter { event in
                tokens.isEmpty || tokens.allSatisfy { token in
                    searchableFields(for: event).contains {
                        $0.localizedCaseInsensitiveContains(token)
                    }
                }
            }
            .sorted(by: eventComparator)
    }

    private func searchableFields(for event: VaultHistoryEvent) -> [String] {
        var fields = [
            event.title,
            event.previousTitle ?? "",
            event.kind.label,
            event.subject.directory ?? "",
            event.subject.sessionId ?? "",
            event.subject.agentDisplayName ?? "",
            event.subject.workspaceId?.uuidString ?? "",
            event.subject.workspaceStableId?.uuidString ?? "",
            event.subject.windowId?.uuidString ?? "",
            event.subject.surfaceId?.uuidString ?? "",
            event.subject.surfaceStableId?.uuidString ?? "",
        ]
        if let rawAgent = event.subject.agent {
            fields.append(rawAgent)
            if event.subject.agentDisplayName == nil,
               let agent = SessionAgent(rawValue: rawAgent) {
                fields.append(agent.displayName)
            }
        }
        return fields
    }

    private func eventComparator(_ lhs: VaultHistoryEvent, _ rhs: VaultHistoryEvent) -> Bool {
        switch sortOrder {
        case .newestFirst:
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id > rhs.id
        case .oldestFirst:
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        case .titleAscending:
            let lhsTitle = sortTitle(for: lhs)
            let rhsTitle = sortTitle(for: rhs)
            let comparison = lhsTitle.localizedStandardCompare(rhsTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id > rhs.id
        }
    }

    private func sortTitle(for event: VaultHistoryEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? event.kind.label : title
    }
}
