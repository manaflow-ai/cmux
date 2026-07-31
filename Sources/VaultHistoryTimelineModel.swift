import Foundation

/// The three user-facing ways to browse History. Each mode owns its
/// primitive and filters out events that cannot belong to that primitive,
/// avoiding catch-all sections such as agent sessions under "Other"
/// in the workspace timeline.
enum VaultHistoryMode: String, CaseIterable, Identifiable, Sendable {
    case timeline
    case folder
    case agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .timeline:
            return String(localized: "vaultPane.tab.timeline", defaultValue: "Timeline")
        case .folder:
            return String(localized: "vaultPane.tab.folder", defaultValue: "By Folder")
        case .agent:
            return String(localized: "vaultPane.tab.agent", defaultValue: "By Agent")
        }
    }

    var symbolName: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .folder: return "folder"
        case .agent: return "person.2"
        }
    }

    var groupKey: VaultHistoryGroupKey {
        switch self {
        case .timeline: return .workspace
        case .folder: return .directory
        case .agent: return .agent
        }
    }

    func includedEvents(from events: [VaultHistoryEvent]) -> [VaultHistoryEvent] {
        events.filter { event in
            switch self {
            case .timeline:
                return event.subject.workspaceId != nil
            case .folder:
                let directory = event.subject.directory?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !directory.isEmpty && directory != "."
            case .agent:
                return event.kind == .sessionActivity && event.subject.agent != nil
            }
        }
    }
}

/// View model for the History timeline: merges persisted lifecycle events
/// with session events derived from the agent-session index, and exposes grouped
/// sections computed by the pure ``VaultHistoryGrouper``.
@MainActor
final class VaultHistoryTimelineModel {
    enum Update {
        case loading
        case content
    }

    var onUpdate: ((Update) -> Void)?

    var mode: VaultHistoryMode {
        didSet {
            guard mode != oldValue else { return }
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
    private(set) var workspaceSections: [VaultHistoryWorkspaceTimelineProjection.Section] = []
    private(set) var resumeEntriesByEventId: [String: SessionEntry] = [:]
    private(set) var isLoading = false
    /// True once the first refresh completed, so the empty state does not
    /// flash before anything loaded.
    private(set) var didLoad = false

    private static let timeRangeDefaultsKey = "vaultHistory.timeRange"
    private static let sortOrderDefaultsKey = "vaultHistory.sortOrder"
    /// Cap on merged timeline size handed to grouping; both inputs are
    /// already bounded by store retention and session index page caps. This is
    /// a final guard so the UI never renders an unbounded list.
    private static let maxTimelineEvents = 3000

    private let log: VaultHistoryEventLog
    private let grouper: VaultHistoryGrouper
    private let projection = VaultHistorySessionEventProjection()
    private let workspaceProjection = VaultHistoryWorkspaceTimelineProjection()
    private let agentBindingStore: VaultHistoryAgentBindingStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private var mergedEvents: [VaultHistoryEvent] = []
    private var topology = VaultHistoryWorkspaceTopology(workspaces: [])
    private var refreshTask: Task<Void, Never>?
    private var isBatchingQueryChanges = false

    var hasActiveFilters: Bool {
        timeRange != .allTime
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        log: VaultHistoryEventLog,
        mode: VaultHistoryMode = .timeline,
        grouper: VaultHistoryGrouper = VaultHistoryGrouper(),
        agentBindingStore: VaultHistoryAgentBindingStore = VaultHistoryAgentBindingStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.log = log
        self.grouper = grouper
        self.agentBindingStore = agentBindingStore
        self.defaults = defaults
        self.now = now
        self.mode = mode
        self.timeRange = defaults.string(forKey: Self.timeRangeDefaultsKey)
            .flatMap(VaultHistoryQuery.TimeRange.init(rawValue:)) ?? .allTime
        self.sortOrder = defaults.string(forKey: Self.sortOrderDefaultsKey)
            .flatMap(VaultHistoryQuery.SortOrder.init(rawValue:)) ?? .newestFirst
    }

    /// Reloads persisted events, merges the given session entries, and
    /// regroups. Coalesces: a refresh requested while one is in flight
    /// cancels and replaces it.
    func refresh(
        sessionEntries: [SessionEntry],
        topology: VaultHistoryWorkspaceTopology
    ) {
        refreshTask?.cancel()
        isLoading = true
        onUpdate?(.loading)
        let log = log
        let agentBindingStore = agentBindingStore
        refreshTask = Task { [weak self] in
            async let recordedEvents = log.recentEvents()
            async let agentBindings = agentBindingStore.load()
            let (recorded, bindings) = await (recordedEvents, agentBindings)
            guard !Task.isCancelled, let self else { return }
            var merged = recorded
            merged.append(contentsOf: self.projection.events(
                from: sessionEntries,
                bindings: bindings
            ))
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
            self.topology = topology
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
        guard hasActiveFilters else { return }
        isBatchingQueryChanges = true
        searchText = ""
        timeRange = .allTime
        isBatchingQueryChanges = false
        regroup()
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func regroup() {
        guard !isBatchingQueryChanges else { return }
        let currentTime = now()
        let query = VaultHistoryQuery(
            timeRange: timeRange,
            sortOrder: sortOrder,
            searchText: searchText
        )
        if mode == .timeline {
            workspaceSections = workspaceProjection.sections(
                topology: topology,
                events: mode.includedEvents(from: mergedEvents),
                query: query,
                now: currentTime
            )
            groups = []
        } else {
            workspaceSections = []
            groups = grouper.groups(
                events: mode.includedEvents(from: mergedEvents),
                by: mode.groupKey,
                query: query,
                now: currentTime
            )
        }
        onUpdate?(.content)
    }
}
