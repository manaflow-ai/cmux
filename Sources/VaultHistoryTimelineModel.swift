import CmuxVaultHistory
import Foundation
import Observation

/// View model for the Vault History tab: merges persisted lifecycle events
/// with session events derived from the Vault index, and exposes grouped
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

    private(set) var groups: [VaultHistoryGroup] = []
    private(set) var isLoading = false
    /// True once the first refresh completed, so the empty state does not
    /// flash before anything loaded.
    private(set) var didLoad = false

    private static let groupKeyDefaultsKey = "vaultHistory.groupKey"
    /// Cap on merged timeline size handed to grouping; both inputs are
    /// already bounded (store retention, session index page caps) — this is
    /// a final guard so the UI never renders an unbounded list.
    private static let maxTimelineEvents = 3000

    private let log: VaultHistoryEventLog
    private let grouper: VaultHistoryGrouper
    private let projection = VaultHistorySessionEventProjection()
    private let defaults: UserDefaults
    private let now: () -> Date
    private var mergedEvents: [VaultHistoryEvent] = []
    private var refreshTask: Task<Void, Never>?

    init(
        log: VaultHistoryEventLog,
        grouper: VaultHistoryGrouper = VaultHistoryGrouper(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { .now }
    ) {
        self.log = log
        self.grouper = grouper
        self.defaults = defaults
        self.now = now
        self.groupKey = defaults.string(forKey: Self.groupKeyDefaultsKey)
            .flatMap(VaultHistoryGroupKey.init(rawValue:)) ?? .date
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
            let projectedSessions = self.projection.events(from: sessionEntries)
            self.mergedEvents = VaultHistoryEvent.mergeNewestFirst(
                recorded,
                projectedSessions,
                limit: Self.maxTimelineEvents
            )
            self.isLoading = false
            self.didLoad = true
            self.regroup()
        }
    }

    private func regroup() {
        groups = grouper.groups(
            newestFirstEvents: mergedEvents,
            by: groupKey,
            now: now()
        )
    }
}
