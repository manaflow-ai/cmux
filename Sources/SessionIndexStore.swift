import AppKit
import Bonsplit
import CMUXAgentLaunch
import Darwin
import Foundation
import Observation
import os
import SQLite3

nonisolated let sessionIndexLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "SessionIndexStore"
)

@MainActor
@Observable
final class SessionIndexStore {
    private(set) var entries: [SessionEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            invalidateSectionsCache()
        }
    }
    private(set) var isLoading: Bool = false
    var scopeToCurrentDirectory: Bool = false {
        didSet {
            guard scopeToCurrentDirectory != oldValue else { return }
            invalidateSectionsCache()
        }
    }
    var currentDirectory: String? = nil {
        didSet {
            guard scopeToCurrentDirectory, currentDirectory != oldValue else { return }
            invalidateSectionsCache()
        }
    }

    func setCurrentDirectoryIfChanged(_ next: String?) {
        guard currentDirectory != next else { return }
        currentDirectory = next
    }

    var grouping: SessionGrouping {
        didSet {
            guard grouping != oldValue else { return }
            UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey)
            invalidateSectionsCache()
            // Switching into directory grouping can expose cwds that were never
            // backfilled while the user was viewing agent grouping.
            if grouping == .directory {
                backfillDirectoryOrderFromEntries()
            } else {
                backfillAgentOrderFromEntries()
            }
        }
    }

    /// Persisted order for agent sections.
    var agentOrder: [SessionAgent] {
        didSet {
            guard !Self.agentOrderPresentationEqual(agentOrder, oldValue) else { return }
            Self.persistAgentOrder(agentOrder)
            invalidateSectionsCache()
        }
    }

    /// Persisted order for directory sections (absolute paths; "" means "no folder").
    var directoryOrder: [String] {
        didSet {
            guard directoryOrder != oldValue else { return }
            Self.persistDirectoryOrder(directoryOrder)
            invalidateSectionsCache()
        }
    }

    private static let groupingKey = "sessionIndex.grouping"
    private static let agentOrderDefaultsKey = "sessionIndex.agentOrder"
    private static let directoryOrderDefaultsKey = "sessionIndex.directoryOrder"
    // Cache bookkeeping is deliberately unobserved (it was not `@Published`
    // pre-@Observable): `sectionsForCurrentGrouping()` writes it from inside
    // view-body computations, and tracked writes there would re-invalidate the
    // very views being rendered.
    @ObservationIgnored var sectionsCacheRevision: UInt64 = 0
    @ObservationIgnored var cachedSectionsRevision: UInt64?
    @ObservationIgnored var cachedSections: [IndexSection] = []

    init() {
        self.agentOrder = Self.loadAgentOrder()
        self.directoryOrder = Self.loadDirectoryOrder()
        let storedGrouping = UserDefaults.standard.string(forKey: Self.groupingKey)
        self.grouping = SessionGrouping(rawValue: storedGrouping ?? "") ?? .directory
    }

    /// Extend `directoryOrder` with any cwds seen in `entries` that aren't
    /// already tracked. Kept out of the view-body path: it mutates observable
    /// state and must only run in response to real data changes (new scan
    /// results, grouping switch) — not on every SwiftUI update tick.
    private func backfillDirectoryOrderFromEntries() {
        let knownPaths = Set(directoryOrder)
        var latestByPath: [String: Date] = [:]
        for entry in entries {
            let path = entry.cwd ?? ""
            guard !knownPaths.contains(path) else { continue }
            if let latest = latestByPath[path] {
                if latest < entry.modified {
                    latestByPath[path] = entry.modified
                }
            } else {
                latestByPath[path] = entry.modified
            }
        }
        guard !latestByPath.isEmpty else { return }
        let additions = latestByPath
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map(\.key)
        directoryOrder.append(contentsOf: additions)
    }

    private func backfillAgentOrderFromEntries() {
        let registeredAgentsByID = Dictionary(
            entries.compactMap { entry -> (String, RegisteredSessionAgent)? in
                guard case .registered(let agent) = entry.agent else { return nil }
                return (agent.id, agent)
            },
            uniquingKeysWith: { existing, replacement in
                existing.name == nil ? replacement : existing
            }
        )
        var nextOrder = agentOrder.map { agent -> SessionAgent in
            guard case .registered(let registered) = agent,
                  let refreshed = registeredAgentsByID[registered.id],
                  refreshed != registered else {
                return agent
            }
            return .registered(refreshed)
        }
        let knownAgentIds = Set(nextOrder.map(\.rawValue))
        var additionsByAgentId: [String: (agent: SessionAgent, latest: Date)] = [:]
        for entry in entries {
            let agentId = entry.agent.rawValue
            guard !knownAgentIds.contains(agentId) else { continue }
            if let existing = additionsByAgentId[agentId] {
                if existing.latest < entry.modified {
                    additionsByAgentId[agentId] = (existing.agent, entry.modified)
                }
            } else {
                additionsByAgentId[agentId] = (entry.agent, entry.modified)
            }
        }
        if additionsByAgentId.isEmpty {
            setAgentOrderIfPresentationChanged(nextOrder)
            return
        }
        let additions = additionsByAgentId.values.sorted { lhs, rhs in
            lhs.latest == rhs.latest
                ? lhs.agent.rawValue < rhs.agent.rawValue
                : lhs.latest > rhs.latest
        }
        nextOrder.append(contentsOf: additions.map(\.agent))
        setAgentOrderIfPresentationChanged(nextOrder)
    }

    private func setAgentOrderIfPresentationChanged(_ nextOrder: [SessionAgent]) {
        guard !Self.agentOrderPresentationEqual(nextOrder, agentOrder) else { return }
        agentOrder = nextOrder
    }

    private func invalidateSectionsCache() {
        sectionsCacheRevision &+= 1
    }

    private static func loadAgentOrder() -> [SessionAgent] {
        let stored = UserDefaults.standard.array(forKey: agentOrderDefaultsKey) as? [String] ?? []
        var ordered: [SessionAgent] = stored.compactMap { SessionAgent(rawValue: $0) }
        for agent in SessionAgent.builtInCases where !ordered.contains(agent) {
            ordered.append(agent)
        }
        var seen = Set<String>()
        ordered = ordered.filter { seen.insert($0.rawValue).inserted }
        return ordered
    }

    private static func loadDirectoryOrder() -> [String] {
        UserDefaults.standard.array(forKey: directoryOrderDefaultsKey) as? [String] ?? []
    }

    private static func persistAgentOrder(_ order: [SessionAgent]) {
        UserDefaults.standard.set(order.map { $0.rawValue }, forKey: agentOrderDefaultsKey)
    }

    private static func agentOrderPresentationEqual(_ lhs: [SessionAgent], _ rhs: [SessionAgent]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left.rawValue == right.rawValue else { return false }
            switch (left, right) {
            case (.registered(let leftAgent), .registered(let rightAgent)):
                return leftAgent.name == rightAgent.name
                    && leftAgent.iconAssetName == rightAgent.iconAssetName
            default:
                return true
            }
        }
    }

    private static func persistDirectoryOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: directoryOrderDefaultsKey)
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func reload() {
        loadTask?.cancel()
        isLoading = true
        directorySnapshotGeneration += 1
        invalidateDirectorySnapshots()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = await Self.scanAll()
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                self.entries = scanned
                self.isLoading = false
                self.backfillAgentOrderFromEntries()
                self.backfillDirectoryOrderFromEntries()
            }
        }
    }

#if DEBUG
    func replaceEntriesForTesting(_ entries: [SessionEntry]) {
        self.entries = entries
        backfillAgentOrderFromEntries()
        backfillDirectoryOrderFromEntries()
    }
#endif

    // MARK: - Directory snapshot cache

    // Unobserved cache state (was not `@Published` pre-@Observable); consumers
    // read snapshots through explicit load calls, never via observation.
    @ObservationIgnored var directorySnapshotCache: [String: DirectorySnapshot] = [:]
    @ObservationIgnored var directorySnapshotLRU: [String] = []
    /// Bumped on every `reload()`. Snapshot builds capture this at start;
    /// if it changes before the build completes (reload raced with an
    /// in-flight build), the build's result is discarded instead of
    /// being written back into the cache — otherwise the stale
    /// pre-reload result would repopulate the cache after invalidation
    /// and be reused on the next popover open.
    @ObservationIgnored var directorySnapshotGeneration: Int = 0
}
