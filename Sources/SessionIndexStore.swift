import CmuxFoundation
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSessionIndex
import Foundation
import Observation
import os
import SQLite3

nonisolated private let sessionIndexLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "SessionIndexStore"
)

// `SessionIndexRipgrepCancellation` moved to CmuxFoundation (Process/).

// `ClaudeMetadataCache` moved to CmuxSessionIndex (Cache/). The store keeps its
// private `claudeMetadataCache` instance and injects it into the nonisolated
// static loader chain exactly as before.

// `SessionDragRegistry` moved to `Sources/SessionDragRegistry.swift` as a
// constructor-injected owner held at the app composition root (the `static let
// shared` singleton was removed). Producer/consumer reach the same instance
// through the injected owner.

// MARK: - Store

// `SessionGrouping`, `SectionKey`, `IndexSection`, and `SectionIcon` moved to
// CmuxSessionIndex (Models/). Typealiased here so the ~consumers stay
// byte-identical. The localized grouping `label` stays app-side (it binds
// `String(localized:)` against the app bundle) as an extension below.
typealias SessionGrouping = CmuxSessionIndex.SessionGrouping
typealias SectionKey = CmuxSessionIndex.SectionKey
typealias IndexSection = CmuxSessionIndex.IndexSection
typealias SectionIcon = CmuxSessionIndex.SectionIcon

extension SessionGrouping {
    var label: String {
        switch self {
        case .directory: return String(localized: "sessionIndex.group.directory", defaultValue: "By folder")
        case .agent: return String(localized: "sessionIndex.group.agent", defaultValue: "By agent")
        }
    }
}

/// Owns the "which section is currently being dragged" bit, separate from
/// `SessionIndexStore`. Isolating this means drag start/end does not invalidate
/// observers of the data store, so rows and gaps don't re-render every time a
/// drag begins or clears.
@MainActor
@Observable
final class SessionDragCoordinator {
    var draggedKey: SectionKey? = nil
}

// `DirectorySnapshot` moved to CmuxSessionIndex (Models/DirectorySnapshot.swift) so the
// package-side "Show more" popover (`SectionPopoverView` in CmuxSessionIndexUI) can consume
// it as a package type. Still produced here by `loadDirectorySnapshot(cwd:)`.

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
    private var sectionsCacheRevision: UInt64 = 0
    private var cachedSectionsRevision: UInt64?
    private var cachedSections: [IndexSection] = []

    /// Store-owned parsed-Claude-metadata cache, injected into the nonisolated
    /// static loader chain (`loadAgents` -> `timedAgent` -> `searchAgent` ->
    /// `loadClaudeEntries`) the same way `ErrorBag` is threaded through.
    nonisolated private let claudeMetadataCache = ClaudeMetadataCache()

    init() {
        self.agentOrder = Self.loadAgentOrder()
        self.directoryOrder = Self.loadDirectoryOrder()
        let storedGrouping = UserDefaults.standard.string(forKey: Self.groupingKey)
        self.grouping = SessionGrouping(rawValue: storedGrouping ?? "") ?? .directory
    }

    /// Returns the sections for the current grouping mode, in the user-saved order.
    func sectionsForCurrentGrouping() -> [IndexSection] {
        if cachedSectionsRevision == sectionsCacheRevision {
            return cachedSections
        }

        let visible = filteredEntriesForCurrentScope()
        let sections: [IndexSection]
        switch grouping {
        case .agent:
            let buckets = Dictionary(grouping: visible, by: { $0.agent.rawValue })
            sections = agentOrder.compactMap { agent in
                guard let entries = buckets[agent.rawValue], !entries.isEmpty else { return nil }
                return IndexSection(
                    key: .agent(agent),
                    title: agent.displayName,
                    icon: .agent(agent),
                    entries: entries
                )
            }
        case .directory:
            let buckets = Dictionary(grouping: visible) { $0.cwd ?? "" }
            // Any cwds that aren't yet in the saved order still need to show
            // up. They get appended by most-recent activity, purely locally,
            // without mutating `directoryOrder` from inside this view-body
            // computation — scheduling a Task here created a state-update
            // feedback loop that pegged the main thread at 100% CPU.
            // Persistent backfill happens via `backfillDirectoryOrderFromEntries`,
            // called from `reload()` and `grouping.didSet`.
            let knownPaths = Set(directoryOrder)
            let unknownSorted = buckets.keys
                .filter { !knownPaths.contains($0) }
                .sorted { lhs, rhs in
                    let lMax = buckets[lhs]?.map(\.modified).max() ?? .distantPast
                    let rMax = buckets[rhs]?.map(\.modified).max() ?? .distantPast
                    return lMax > rMax
                }
            sections = (directoryOrder + unknownSorted)
                .filter { buckets[$0] != nil }
                .map { path in
                    IndexSection(
                        key: .directory(path.isEmpty ? nil : path),
                        title: directoryDisplayName(path),
                        icon: .folder,
                        entries: buckets[path] ?? []
                    )
                }
        }

        cachedSections = sections
        cachedSectionsRevision = sectionsCacheRevision
        return sections
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

    private func filteredEntriesForCurrentScope() -> [SessionEntry] {
        guard scopeToCurrentDirectory, let dir = normalizedDirectory(currentDirectory) else {
            return entries
        }
        return entries.filter { entry in
            guard let cwd = normalizedDirectory(entry.cwd) else { return false }
            return cwd == dir || cwd.hasPrefix(dir + "/")
        }
    }

    private func directoryDisplayName(_ path: String) -> String {
        if path.isEmpty {
            return String(localized: "sessionIndex.directory.unknown", defaultValue: "(no folder)")
        }
        return (path as NSString).lastPathComponent
    }

    /// Move `key` so it lands immediately before `referenceKey` in the
    /// persisted order (or at the end if `referenceKey` is nil). Anchoring
    /// to a neighbor key (rather than a positional index) means scope filters
    /// can hide some sections without corrupting reorders: hidden sections
    /// keep their relative position to their visible neighbors.
    func moveSection(_ key: SectionKey, before referenceKey: SectionKey?) {
        switch grouping {
        case .agent:
            guard key.raw.hasPrefix("agent:"),
                  let agent = SessionAgent(rawValue: String(key.raw.dropFirst("agent:".count))) else { return }
            guard let oldIndex = agentOrder.firstIndex(where: { $0.rawValue == agent.rawValue }) else { return }
            var next = agentOrder
            let moved = next.remove(at: oldIndex)
            if let referenceKey,
               referenceKey.raw.hasPrefix("agent:"),
               let refAgent = SessionAgent(rawValue: String(referenceKey.raw.dropFirst("agent:".count))),
               let refIndex = next.firstIndex(where: { $0.rawValue == refAgent.rawValue }) {
                next.insert(moved, at: refIndex)
            } else {
                next.append(moved)
            }
            if next != agentOrder { agentOrder = next }
        case .directory:
            guard key.raw.hasPrefix("dir:") else { return }
            let path = String(key.raw.dropFirst("dir:".count))
            guard let oldIndex = directoryOrder.firstIndex(of: path) else { return }
            var next = directoryOrder
            next.remove(at: oldIndex)
            if let referenceKey,
               referenceKey.raw.hasPrefix("dir:") {
                let refPath = String(referenceKey.raw.dropFirst("dir:".count))
                if let refIndex = next.firstIndex(of: refPath) {
                    next.insert(path, at: refIndex)
                } else {
                    next.append(path)
                }
            } else {
                next.append(path)
            }
            if next != directoryOrder { directoryOrder = next }
        }
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

    private struct LoadedAgentOrder: Sendable {
        let agents: [SessionAgent]
        let registry: CmuxVaultAgentRegistry
    }

    nonisolated private static func defaultAgentOrder(workingDirectory: String?) async -> LoadedAgentOrder {
        await Task.detached(priority: .utility) {
            defaultAgentOrderSync(workingDirectory: workingDirectory)
        }.value
    }

    nonisolated private static func defaultAgentOrderSync(workingDirectory: String?) -> LoadedAgentOrder {
        let builtInIDs = Set(SessionAgent.builtInCases.map(\.rawValue))
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: workingDirectory)
        let agents = SessionAgent.builtInCases + registry.registrations.compactMap {
            builtInIDs.contains($0.id) ? nil : .registered(RegisteredSessionAgent(registration: $0))
        }
        return LoadedAgentOrder(agents: agents, registry: registry)
    }

    nonisolated private static func vaultAgentRegistry(workingDirectory: String?) async -> CmuxVaultAgentRegistry {
        await Task.detached(priority: .utility) {
            CmuxVaultAgentRegistry.load(workingDirectory: workingDirectory)
        }.value
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

    private var loadTask: Task<Void, Never>?

    func reload() {
        loadTask?.cancel()
        isLoading = true
        directorySnapshotGeneration += 1
        invalidateDirectorySnapshots()
        let claudeMetadataCache = self.claudeMetadataCache
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = await Self.scanAll(claudeMetadataCache: claudeMetadataCache)
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

    private var directorySnapshotCache: [String: DirectorySnapshot] = [:]
    private var directorySnapshotLRU: [String] = []
    /// Bumped on every `reload()`. Snapshot builds capture this at start;
    /// if it changes before the build completes (reload raced with an
    /// in-flight build), the build's result is discarded instead of
    /// being written back into the cache — otherwise the stale
    /// pre-reload result would repopulate the cache after invalidation
    /// and be reused on the next popover open.
    private var directorySnapshotGeneration: Int = 0
    private static let directorySnapshotCacheCapacity = 16

    /// Return a cached or freshly-built merged snapshot for a cwd-scoped
    /// directory. Used by the Show-more popover's empty-query scroll
    /// path: the popover slices this array in memory instead of asking
    /// the store for more pages on every scroll, eliminating the O(n²)
    /// repeated-refetch-and-merge behavior.
    func loadDirectorySnapshot(cwd: String?) async -> DirectorySnapshot {
        let key = cwd ?? ""
        if let cached = touchDirectorySnapshotLRU(key) {
            return cached
        }

        let generation = directorySnapshotGeneration
        let bag = ErrorBag()
        // The per-agent loaders interpret `cwdFilter == nil` as "no filter,
        // return all entries". When `cwd` is nil here we specifically mean
        // the "(no folder)" bucket — entries that genuinely have no cwd.
        // Fetch unfiltered and post-filter locally to preserve that scope.
        let noFolderScope = (cwd == nil) || ((cwd ?? "").isEmpty)
        let cwdFilter = noFolderScope ? nil : cwd
        // Large limit so every per-agent loader returns all matching rows.
        // Claude's `searchMaxFiles` cap still applies (currently 1500); if
        // anyone has more Claude sessions in a single cwd we'll bump it.
        let bigLimit = 10_000
        let order = await Self.defaultAgentOrder(workingDirectory: cwdFilter)
        var merged = await Self.loadAgents(
            order.agents,
            registry: order.registry,
            needle: "",
            cwdFilter: cwdFilter,
            offset: 0,
            limit: bigLimit,
            errorBag: bag,
            claudeMetadataCache: claudeMetadataCache
        )
        if Task.isCancelled {
            return DirectorySnapshot(cwd: key, entries: [], errors: [])
        }
        if noFolderScope {
            merged = merged.filter { ($0.cwd ?? "").isEmpty }
        }
        let sorted = merged.sorted { $0.modified > $1.modified }
        let snapshot = DirectorySnapshot(cwd: key, entries: sorted, errors: bag.snapshot())
        // Only cache this result if no `reload()` raced in while the
        // build was running. Otherwise the caller gets a fresh snapshot
        // but the cache stays invalidated; the next open will rebuild.
        if generation == directorySnapshotGeneration {
            storeDirectorySnapshot(key: key, snapshot: snapshot)
        }
        return snapshot
    }

    private func touchDirectorySnapshotLRU(_ key: String) -> DirectorySnapshot? {
        guard let cached = directorySnapshotCache[key] else { return nil }
        if let idx = directorySnapshotLRU.firstIndex(of: key) {
            directorySnapshotLRU.remove(at: idx)
        }
        directorySnapshotLRU.append(key)
        return cached
    }

    private func storeDirectorySnapshot(key: String, snapshot: DirectorySnapshot) {
        if directorySnapshotCache[key] == nil,
           directorySnapshotCache.count >= Self.directorySnapshotCacheCapacity,
           let oldestKey = directorySnapshotLRU.first {
            directorySnapshotCache.removeValue(forKey: oldestKey)
            directorySnapshotLRU.removeFirst()
        }
        directorySnapshotCache[key] = snapshot
        if let idx = directorySnapshotLRU.firstIndex(of: key) {
            directorySnapshotLRU.remove(at: idx)
        }
        directorySnapshotLRU.append(key)
    }

    private func invalidateDirectorySnapshots() {
        directorySnapshotCache.removeAll()
        directorySnapshotLRU.removeAll()
    }

    private func normalizedDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var path = (value as NSString).standardizingPath
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: - Scanning

    private static let perAgentLimit = 30
    nonisolated static let headByteCap = 64 * 1024
    nonisolated static let tailByteCap = 32 * 1024
    /// Hard cap on candidate files inspected per call to keep deep-page searches bounded.
    nonisolated static let searchMaxFiles = 1500

    nonisolated private static func scanAll(
        claudeMetadataCache: ClaudeMetadataCache
    ) async -> [SessionEntry] {
        // Initial scan errors are silently ignored — UI just shows the cached
        // entries we did get. Errors get surfaced when the user actively
        // searches via the popover.
        let bag = ErrorBag()
        let order = await defaultAgentOrder(workingDirectory: nil)
        let combined = await loadAgents(
            order.agents,
            registry: order.registry,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: perAgentLimit,
            errorBag: bag,
            claudeMetadataCache: claudeMetadataCache
        )
        return combined.sorted { $0.modified > $1.modified }
    }

    // `ClaudeParsed` moved to CmuxFoundation as `TranscriptMetadataParser.ClaudeTranscriptMetadata`.

    // The Claude filesystem-discovery cluster (`ClaudeSessionRoot`,
    // `ClaudeSessionCandidate`, `claudeSessionRoots()`, and
    // `enumerateClaudeJSONLCandidates(root:cwdFilter:prefilteredByRipgrep:)`) moved
    // to CmuxFoundation as `ClaudeSessionDiscovery`. The three app-side dependencies
    // are injected as closures into the `claudeSessionDiscovery` service below:
    // `ClaudeConfigDirectoryPath.preferredPath`,
    // `ClaudeConfigurationRoot.configuredResumeDirectory`, and
    // `RestorableAgentSessionIndex.encodeClaudeProjectDir`.

    // `extractClaudeMetadata`, `decodeClaudeProjectDir`, and `claudeProjectDirName`
    // moved to CmuxFoundation (`TranscriptMetadataParser`). The app-side
    // `SessionEntry.claudeDisplayTitle` is passed in as the parser's `displayTitle`
    // closure, and the parser-owned `TranscriptPullRequestLink` is mapped onto
    // `PullRequestLink` at the call site.
    // `realCodexUserMessage(_:)` moved to CmuxFoundation (RipgrepFileScanner).

    // MARK: Codex

    // `CodexParsed`, `peekCodexSessionMetaCwd`, and `extractCodexMetadata` moved to
    // CmuxFoundation (`TranscriptMetadataParser`, result type
    // `CodexTranscriptMetadata`). `forEachJSONLine(url:maxBytes:body:)` and
    // `realCodexUserMessage(_:)` already live on CmuxFoundation's RipgrepFileScanner.

    // MARK: OpenCode

    // `parseOpenCodeAssistant(_:)` moved to CmuxFoundation (`TranscriptMetadataParser`).

    // `sqliteText`/`sqliteMessage` moved to CmuxFoundation as
    // `OpaquePointer.sqliteColumnText(_:)` and `OpaquePointer.sqliteErrorMessage`.

    // MARK: - Deep search (popover "Show more")

    // `SearchScope` and `SearchOutcome` moved to CmuxSessionIndex (Models/).
    // Kept as nested typealiases so `SessionIndexStore.SearchScope` /
    // `SessionIndexStore.SearchOutcome` (views/tests) and the bare
    // `SearchScope` / `SearchOutcome` spellings in the store's extension files
    // (Hermes/RovoDev/Codex) stay byte-identical.
    typealias SearchScope = CmuxSessionIndex.SearchScope
    typealias SearchOutcome = CmuxSessionIndex.SearchOutcome

    /// Paginated on-demand search across the full filesystem (Claude/Codex) and
    /// SQLite (OpenCode). Empty query is allowed and returns the most-recent
    /// entries (used when the user just opens the popover and scrolls).
    /// Returns up to `limit` entries sorted by mtime desc, skipping the first
    /// `offset` matches.
    func searchSessions(
        query: String,
        scope: SearchScope,
        offset: Int,
        limit: Int
    ) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let bag = ErrorBag()
        #if DEBUG
        let totalStart = ProcessInfo.processInfo.systemUptime
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000
            cmuxDebugLog("session.search.total ms=\(String(format: "%.0f", totalMs)) needle=\"\(trimmed.prefix(20))\" offset=\(offset) limit=\(limit) errors=\(bag.snapshot().count)")
        }
        #endif
        let entries: [SessionEntry]
        switch scope {
        case .agent(let a):
            let registry: CmuxVaultAgentRegistry
            let cwdFilter: String?
            if case .registered = a {
                let scopedCwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                cwdFilter = scopedCwd?.isEmpty == false ? scopedCwd : nil
                registry = await Self.vaultAgentRegistry(workingDirectory: cwdFilter)
            } else if a == .grok {
                let scopedCwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                cwdFilter = scopedCwd?.isEmpty == false ? scopedCwd : nil
                registry = await Self.vaultAgentRegistry(
                    workingDirectory: cwdFilter
                )
            } else {
                cwdFilter = nil
                registry = CmuxVaultAgentRegistry(registrations: [])
            }
            entries = await Self.searchAgent(
                needle: needle, agent: a, cwdFilter: cwdFilter,
                offset: offset, limit: limit, errorBag: bag, registry: registry
            )
        case .directory(let path):
            let noFolderScope = (path == nil) || ((path ?? "").isEmpty)
            let cwdFilter = noFolderScope ? nil : path
            // Multi-agent merge: fetch the union of (offset+limit) per agent so the
            // merge-sort can produce a stable global ordering, then slice.
            let target = offset + limit
            let order = await Self.defaultAgentOrder(workingDirectory: cwdFilter)
            var merged = await Self.loadAgents(
                order.agents,
                registry: order.registry,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: 0,
                limit: target,
                errorBag: bag,
                claudeMetadataCache: claudeMetadataCache
            )
            if noFolderScope {
                merged = merged.filter { ($0.cwd ?? "").isEmpty }
            }
            let sorted = merged.sorted { $0.modified > $1.modified }
            entries = Array(sorted.dropFirst(offset).prefix(limit))
        }
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }

    nonisolated private static func loadAgents(
        _ agents: [SessionAgent],
        registry: CmuxVaultAgentRegistry,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        claudeMetadataCache: ClaudeMetadataCache
    ) async -> [SessionEntry] {
        await withTaskGroup(of: [SessionEntry].self) { group in
            for agent in agents {
                group.addTask {
                    await timedAgent(
                        needle: needle,
                        agent: agent,
                        cwdFilter: cwdFilter,
                        offset: offset,
                        limit: limit,
                        errorBag: errorBag,
                        registry: registry,
                        claudeMetadataCache: claudeMetadataCache
                    )
                }
            }
            var merged: [SessionEntry] = []
            for await entries in group {
                merged.append(contentsOf: entries)
            }
            return merged
        }
    }

    nonisolated private static func timedAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag,
        registry: CmuxVaultAgentRegistry,
        claudeMetadataCache: ClaudeMetadataCache
    ) async -> [SessionEntry] {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let result = await searchAgent(
            needle: needle,
            agent: agent,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: errorBag,
            registry: registry,
            claudeMetadataCache: claudeMetadataCache
        )
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        cmuxDebugLog("session.search.agent agent=\(agent.rawValue) ms=\(String(format: "%.0f", ms)) results=\(result.count) cwd=\(cwdFilter?.suffix(40) ?? "nil")")
        return result
        #else
        return await searchAgent(
            needle: needle,
            agent: agent,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: errorBag,
            registry: registry,
            claudeMetadataCache: claudeMetadataCache
        )
        #endif
    }

    nonisolated private static func searchAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag,
        registry: CmuxVaultAgentRegistry,
        claudeMetadataCache: ClaudeMetadataCache
    ) async -> [SessionEntry] {
        switch agent {
        case .claude: return await loadClaudeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, claudeMetadataCache: claudeMetadataCache)
        case .codex: return await loadCodexEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .grok:
            return await loadGrokEntries(
                registration: registry.registration(id: "grok") ?? .builtInGrok,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        case .opencode: return loadOpenCodeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .rovodev: return loadRovoDevEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .hermesAgent: return loadHermesAgentEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .registered(let agent):
            guard let registration = registry.registration(id: agent.id) else {
                return []
            }
            return await loadRegisteredAgentEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        }
    }

    /// Path to `rg` (ripgrep), if installed. nil when not found — the search
    /// code falls back to the Foundation substring scan.
    ///
    /// Stays app-side: it maps `RipgrepExecutableResolver` (which reads app
    /// `RipgrepIntegrationSettings`) and emits the not-executable warning. It is
    /// the resolver injected into `ripgrepScanner` so CmuxFoundation never reaches
    /// app-side ripgrep-path resolution.
    nonisolated private static func resolvedRipgrepPath() -> String? {
        switch RipgrepExecutableResolver.resolution() {
        case .found(let executable):
            return executable.url.path
        case .configuredPathNotExecutable(let path):
            sessionIndexLogger.warning(
                "Configured ripgrep path is not executable; falling back to Foundation session search: \(path, privacy: .public)"
            )
            return nil
        case .notFound:
            return nil
        }
    }

    /// Transcript-scan substrate (rg pre-filter + bounded file-head reads), lifted
    /// to CmuxFoundation. The ripgrep path is resolved through the app-side
    /// `resolvedRipgrepPath()` closure injected here.
    nonisolated static let ripgrepScanner = RipgrepFileScanner(
        ripgrepPathResolver: { resolvedRipgrepPath() }
    )

    /// Pure transcript-metadata parser (Claude/Codex/OpenCode), lifted to
    /// CmuxFoundation. Shares the `ripgrepScanner` for the bounded Codex reads and
    /// the same `headByteCap` so the Codex head-peek behavior is unchanged.
    nonisolated static let transcriptParser = TranscriptMetadataParser(
        scanner: ripgrepScanner,
        headByteCap: headByteCap
    )

    /// Claude transcript filesystem discovery (configured roots + `*.jsonl`
    /// candidate enumeration), lifted to CmuxFoundation. The three app-side
    /// dependencies are injected as closures: config-dir standardization
    /// (`ClaudeConfigDirectoryPath.preferredPath`), resume-directory resolution
    /// (`ClaudeConfigurationRoot.configuredResumeDirectory`), and Claude project
    /// directory encoding (`RestorableAgentSessionIndex.encodeClaudeProjectDir`),
    /// so the package stays decoupled from those higher/app-side seams.
    nonisolated static let claudeSessionDiscovery = ClaudeSessionDiscovery(
        preferredConfigDirectoryPath: { configDir, fileManager in
            ClaudeConfigDirectoryPath.preferredPath(configDir, fileManager: fileManager)
        },
        configuredResumeDirectory: { configDir, fileManager in
            ClaudeConfigurationRoot(fileManager: fileManager).configuredResumeDirectory(configDir)
        },
        encodeClaudeProjectDir: { cwd in
            RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        }
    )

    /// Returns Claude session entries paginated by mtime desc.
    /// - When `needle` is empty: fast path. Skips rg, enumerates configured Claude
    ///   roots, takes the top `offset+limit` by mtime, parses metadata, returns the slice.
    /// - When `needle` is non-empty and rg is on PATH: rg pre-filters the candidate
    ///   set; we only parse files that actually contain the needle.
    /// - When `needle` is non-empty and rg is missing/failed: falls back to the
    ///   Foundation enumeration + 64 KB head + 32 KB tail substring scan.
    nonisolated private static func loadClaudeEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        claudeMetadataCache: ClaudeMetadataCache
    ) async -> [SessionEntry] {
        let roots = claudeSessionDiscovery.sessionRoots()
        guard !roots.isEmpty else { return [] }
        let fm = FileManager.default

        // Pre-filter via rg when we have a needle — rg is parallel, mmaps the
        // file, and scans the WHOLE file (not just our 128 KB head), so it both
        // speeds the scan up and finds matches deeper in long transcripts.
        var candidates: [ClaudeSessionDiscovery.SessionCandidate] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepScanner.matchingPaths(
                    needle: needle,
                    root: root.projectsRoot,
                    fileGlob: "*.jsonl"
                ) else {
                    candidates.append(
                        contentsOf: claudeSessionDiscovery.enumerateJSONLCandidates(
                            root: root,
                            cwdFilter: cwdFilter,
                            prefilteredByRipgrep: false
                        )
                    )
                    continue
                }
                for url in rgPaths {
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    let dirName = transcriptParser.claudeProjectDirName(for: url, projectsRoot: root.projectsRoot)
                    candidates.append(
                        ClaudeSessionDiscovery.SessionCandidate(
                            url: url,
                            mtime: mtime,
                            dirName: dirName,
                            resumeConfigDirectory: root.resumeConfigDirectory,
                            prefilteredByRipgrep: true
                        )
                    )
                }
            }
        } else if let cwdFilter {
            // Fast path: the project directory name encodes the cwd. We can skip
            // enumerating every other project entirely.
            for root in roots {
                candidates.append(
                    contentsOf: claudeSessionDiscovery.enumerateJSONLCandidates(
                        root: root,
                        cwdFilter: cwdFilter,
                        prefilteredByRipgrep: false
                    )
                )
            }
        } else {
            for root in roots {
                candidates.append(
                    contentsOf: claudeSessionDiscovery.enumerateJSONLCandidates(
                        root: root,
                        cwdFilter: nil,
                        prefilteredByRipgrep: false
                    )
                )
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // Take a generous window of candidates to inspect in parallel. We need
        // enough to cover both targets and skipped files; we'll trim to
        // (offset+limit) matches afterwards. Cap at searchMaxFiles.
        let target = offset + limit
        let workSize = min(target * 2, candidates.count, searchMaxFiles)
        let workCandidates = Array(candidates.prefix(workSize))

        #if DEBUG
        let loopStart = ProcessInfo.processInfo.systemUptime
        #endif

        // Parallelize per-file work. Each file's read + parse is independent;
        // running them in a TaskGroup lets the cooperative pool fan I/O out
        // across cores instead of one-file-at-a-time blocking on disk.
        let processed: [(Int, SessionEntry?, Bool)] = await withTaskGroup(
            of: (Int, SessionEntry?, Bool).self
        ) { group in
            for (idx, candidate) in workCandidates.enumerated() {
                group.addTask {
                    // Cache hit
                    let cached = await claudeMetadataCache.get(url: candidate.url, mtime: candidate.mtime)
                    if let cached, needle.isEmpty || candidate.prefilteredByRipgrep {
                        if let cwdFilter, cached.cwd != cwdFilter { return (idx, nil, true) }
                        return (
                            idx,
                            cached.withClaudeConfigDirectoryForResume(candidate.resumeConfigDirectory),
                            true
                        )
                    }
                    let head = ripgrepScanner.readFileHead(url: candidate.url, byteCap: headByteCap)
                    let tail = ripgrepScanner.readFileTail(url: candidate.url, byteCap: tailByteCap)
                    if !needle.isEmpty && !candidate.prefilteredByRipgrep {
                        let combined = head + "\n" + tail
                        if combined.range(of: needle, options: [.caseInsensitive, .literal]) == nil {
                            return (idx, nil, false)
                        }
                    }
                    if let cached {
                        if let cwdFilter, cached.cwd != cwdFilter { return (idx, nil, true) }
                        return (
                            idx,
                            cached.withClaudeConfigDirectoryForResume(candidate.resumeConfigDirectory),
                            true
                        )
                    }
                    let parsed = transcriptParser.extractClaudeMetadata(
                        head: head,
                        tail: tail,
                        projectDir: candidate.dirName,
                        displayTitle: { content, isMeta in
                            SessionEntry.claudeDisplayTitle(from: content, isMeta: isMeta)
                        }
                    )
                    if let cwdFilter, parsed.cwd != cwdFilter { return (idx, nil, false) }
                    let sid = candidate.url.deletingPathExtension().lastPathComponent
                    let pullRequest = parsed.pr.map {
                        PullRequestLink(number: $0.number, url: $0.url, repository: $0.repository)
                    }
                    let entry = SessionEntry(
                        id: "claude:" + candidate.url.path,
                        agent: .claude,
                        sessionId: sid,
                        title: parsed.title,
                        cwd: parsed.cwd,
                        gitBranch: parsed.branch,
                        pullRequest: pullRequest,
                        modified: candidate.mtime,
                        fileURL: candidate.url,
                        specifics: .claude(
                            model: parsed.model,
                            permissionMode: parsed.permissionMode,
                            configDirectoryForResume: candidate.resumeConfigDirectory
                        )
                    )
                    if needle.isEmpty {
                        await claudeMetadataCache.put(
                            url: candidate.url,
                            mtime: candidate.mtime,
                            entry: entry
                        )
                    }
                    return (idx, entry, false)
                }
            }
            var collected: [(Int, SessionEntry?, Bool)] = []
            collected.reserveCapacity(workCandidates.count)
            for await item in group { collected.append(item) }
            return collected
        }
        // Restore original mtime ordering (TaskGroup completes out-of-order).
        let sorted = processed.sorted { $0.0 < $1.0 }
        let matched = sorted.compactMap { $0.1 }
        #if DEBUG
        let cachedCount = sorted.filter { $0.2 }.count
        let skippedCount = sorted.filter { $0.1 == nil && !$0.2 }.count + sorted.filter { $0.1 == nil && $0.2 }.count
        let totalMs = (ProcessInfo.processInfo.systemUptime - loopStart) * 1000
        cmuxDebugLog("session.claude.detail target=\(target) workSize=\(workSize) matched=\(matched.count) cachedHits=\(cachedCount) skipped=\(skippedCount) parallelMs=\(Int(totalMs))")
        #endif
        return Array(matched.prefix(target).dropFirst(offset).prefix(limit))
    }

    /// Returns Codex session entries paginated by mtime desc.
    /// Primary path: query Codex's own `~/.codex/state_5.sqlite` (`threads`
    /// table) — Codex pre-extracts cwd, title, model, branch, approval, sandbox,
    /// effort, and rollout_path so we don't need to read jsonl files at all.
    /// Fallback (DB missing): the file-scan path below.
    nonisolated private static func loadCodexEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag
    ) async -> [SessionEntry] {
        if let viaSQL = await loadCodexEntriesViaSQL(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit,
            errorBag: errorBag
        ) {
            return viaSQL
        }
        return await loadCodexEntriesFromDisk(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit
        )
    }

    nonisolated static func fileContainsNeedle(url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
    }

    /// Disk-scan fallback for Codex when state_5.sqlite isn't present (very old
    /// Codex installs, or non-default config). Same shape as the original loader.
    nonisolated private static func loadCodexEntriesFromDisk(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) async -> [SessionEntry] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        let fm = FileManager.default

        var rgFiltered = false
        var candidates: [(URL, Date)] = []
        if !needle.isEmpty,
           let rgPaths = await ripgrepScanner.matchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") {
            rgFiltered = true
            for url in rgPaths {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append((url, mtime))
            }
        } else {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true,
                      let mtime = values?.contentModificationDate else { continue }
                candidates.append((url, mtime))
            }
        }
        candidates.sort { $0.1 > $1.1 }

        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        for (url, mtime) in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1
            if !needle.isEmpty && !rgFiltered {
                let head = ripgrepScanner.readFileHead(url: url, byteCap: headByteCap)
                guard head.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }
            // Fast cwd reject: session_meta is the FIRST line of every Codex
            // rollout. Pull just that line and bail before streaming the
            // (potentially MB-sized) rest of the file looking for title/branch.
            if let cwdFilter,
               let firstLineCwd = transcriptParser.peekCodexSessionMetaCwd(url: url),
               firstLineCwd != cwdFilter {
                continue
            }
            let parsed = transcriptParser.extractCodexMetadata(url: url)
            if let cwdFilter, parsed.cwd != cwdFilter { continue }
            matches.append(SessionEntry(
                id: "codex:" + url.path,
                agent: .codex,
                sessionId: parsed.sessionId,
                title: parsed.title,
                cwd: parsed.cwd,
                gitBranch: parsed.branch,
                pullRequest: nil,
                modified: mtime,
                fileURL: url,
                specifics: .codex(
                    model: parsed.model,
                    approvalPolicy: parsed.approvalPolicy,
                    sandboxMode: parsed.sandboxMode,
                    effort: parsed.effort
                )
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    /// Returns OpenCode session entries paginated by `time_updated` desc.
    /// Empty needle skips the `LIKE` clause entirely so it's just `ORDER BY … LIMIT/OFFSET`.
    /// Sync because the SQL pass is fast and SQLite's API is sync; the caller
    /// awaits the wrapping `searchSessions`/`scanAll` boundaries.
    nonisolated private static func loadOpenCodeEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag
    ) -> [SessionEntry] {
        let snapshot: OpenCodeDatabaseSnapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(prefix: "cmux-opencode-search") else {
                return []
            }
            snapshot = madeSnapshot
        } catch {
            let format = String(
                localized: "sessionIndex.error.openCodeSnapshot",
                defaultValue: "OpenCode: cannot snapshot opencode.db (%@)"
            )
            errorBag.add(String(format: format, error.localizedDescription))
            return []
        }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            errorBag.add("OpenCode: cannot open opencode.db (\(db?.sqliteErrorMessage ?? "unknown error"))")
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var sql = """
            SELECT s.id, s.title, s.directory, s.time_updated, (
                SELECT data FROM message
                WHERE session_id = s.id AND data LIKE '%"role":"assistant"%'
                ORDER BY time_created DESC LIMIT 1
            ) AS last_assistant
            FROM session s
            """
        var conditions: [String] = []
        if !needle.isEmpty {
            conditions.append("(LOWER(s.title) LIKE ? OR LOWER(s.directory) LIKE ?)")
        }
        if cwdFilter != nil {
            conditions.append("s.directory = ?")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY s.time_updated DESC LIMIT \(limit) OFFSET \(offset)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            errorBag.add("OpenCode: schema unsupported — \(db.sqliteErrorMessage ?? "prepare failed")")
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        if !needle.isEmpty {
            let likePattern = "%\(needle)%"
            sqlite3_bind_text(stmt, bindIndex, likePattern, -1, SQLITE_TRANSIENT_FN); bindIndex += 1
            sqlite3_bind_text(stmt, bindIndex, likePattern, -1, SQLITE_TRANSIENT_FN); bindIndex += 1
        }
        if let cwdFilter {
            sqlite3_bind_text(stmt, bindIndex, cwdFilter, -1, SQLITE_TRANSIENT_FN); bindIndex += 1
        }

        var results: [SessionEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = stmt.sqliteColumnText(0) ?? ""
            let title = stmt.sqliteColumnText(1) ?? ""
            let directory = stmt.sqliteColumnText(2)
            let updatedMs = sqlite3_column_int64(stmt, 3)
            let modified = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
            let lastJSON = stmt.sqliteColumnText(4)
            let (providerModel, agentName) = transcriptParser.parseOpenCodeAssistant(lastJSON)
            results.append(SessionEntry(
                id: "opencode:" + sid,
                agent: .opencode,
                sessionId: sid,
                title: title,
                cwd: directory,
                gitBranch: nil,
                pullRequest: nil,
                modified: modified,
                fileURL: nil,
                specifics: .opencode(providerModel: providerModel, agentName: agentName)
            ))
        }
        return results
    }

    // MARK: Helpers

    // `readFileHead(url:byteCap:)` moved to CmuxFoundation (RipgrepFileScanner).

    // `readFileTail(url:byteCap:)` moved to CmuxFoundation (RipgrepFileScanner).
}
