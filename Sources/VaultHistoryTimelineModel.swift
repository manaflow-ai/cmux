import Foundation
import Observation

/// View model for the History timeline: merges persisted lifecycle events
/// with session events derived from the agent-session index, and exposes grouped
/// sections computed by the pure ``VaultHistoryGrouper``.
@MainActor
@Observable
final class VaultHistoryTimelineModel {
    /// Persisted grouping selection. Defaults to date (last-24-hours first).
    var groupKey: VaultHistoryGroupKey {
        didSet {
            guard groupKey != oldValue else { return }
            defaults.set(groupKey.rawValue, forKey: Self.groupKeyDefaultsKey)
            regroup()
        }
    }

    var timeRange: VaultHistoryQuery.TimeRange {
        didSet {
            guard timeRange != oldValue else { return }
            defaults.set(timeRange.rawValue, forKey: Self.timeRangeDefaultsKey)
            regroup()
        }
    }

    var sortOrder: VaultHistoryQuery.SortOrder {
        didSet {
            guard sortOrder != oldValue else { return }
            defaults.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
            regroup()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            regroup()
        }
    }

    private(set) var groups: [VaultHistoryGroup] = []
    private(set) var resumeEntriesByEventId: [String: SessionEntry] = [:]
    private(set) var isLoading = false
    /// True once the first refresh completed, so the empty state does not
    /// flash before anything loaded.
    private(set) var didLoad = false

    private static let groupKeyDefaultsKey = "vaultHistory.groupKey"
    private static let timeRangeDefaultsKey = "vaultHistory.timeRange"
    private static let sortOrderDefaultsKey = "vaultHistory.sortOrder"
    /// Cap on merged timeline size handed to grouping; both inputs are
    /// already bounded by store retention and session index page caps. This is
    /// a final guard so the UI never renders an unbounded list.
    private static let maxTimelineEvents = 3000

    private let log: VaultHistoryEventLog
    private let grouper: VaultHistoryGrouper
    private let projection = VaultHistorySessionEventProjection()
    private let defaults: UserDefaults
    private let now: () -> Date
    private var mergedEvents: [VaultHistoryEvent] = []
    private var refreshTask: Task<Void, Never>?

    var hasActiveFilters: Bool {
        timeRange != .allTime
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        log: VaultHistoryEventLog,
        grouper: VaultHistoryGrouper = VaultHistoryGrouper(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.log = log
        self.grouper = grouper
        self.defaults = defaults
        self.now = now
        self.groupKey = defaults.string(forKey: Self.groupKeyDefaultsKey)
            .flatMap(VaultHistoryGroupKey.init(rawValue:)) ?? .date
        self.timeRange = defaults.string(forKey: Self.timeRangeDefaultsKey)
            .flatMap(VaultHistoryQuery.TimeRange.init(rawValue:)) ?? .allTime
        self.sortOrder = defaults.string(forKey: Self.sortOrderDefaultsKey)
            .flatMap(VaultHistoryQuery.SortOrder.init(rawValue:)) ?? .newestFirst
    }

    /// Reloads persisted events, merges the given session entries, and
    /// regroups. Coalesces: a refresh requested while one is in flight
    /// cancels and replaces it.
    func refresh(sessionEntries: [SessionEntry]) {
        refreshTask?.cancel()
        isLoading = true
        let log = log
        refreshTask = Task { [weak self] in
            let recorded = await log.recentEvents()
            guard !Task.isCancelled, let self else { return }
            var merged = recorded
            merged.append(contentsOf: self.projection.events(from: sessionEntries))
            // Ordering is the grouper's job; sort here only when the cap
            // forces dropping the oldest events, so the common path pays
            // for a single sort per refresh.
            if merged.count > Self.maxTimelineEvents {
                merged.sort {
                    if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                    return $0.id > $1.id
                }
                merged.removeLast(merged.count - Self.maxTimelineEvents)
            }
            self.mergedEvents = merged
            var resumeEntries: [String: SessionEntry] = [:]
            for entry in sessionEntries {
                resumeEntries["session:\(entry.agent.rawValue):\(entry.id)"] = entry
            }
            self.resumeEntriesByEventId = resumeEntries
            self.isLoading = false
            self.didLoad = true
            self.regroup()
        }
    }

    func clearFilters() {
        searchText = ""
        timeRange = .allTime
    }

    private func regroup() {
        let currentTime = now()
        let query = VaultHistoryQuery(
            timeRange: timeRange,
            sortOrder: sortOrder,
            searchText: searchText
        )
        groups = grouper.groups(
            events: mergedEvents,
            by: groupKey,
            query: query,
            now: currentTime
        )
    }
}
