import AppKit
import Bonsplit
import Combine
import Foundation
import SQLite3

// MARK: - Agents

enum SessionAgent: String, CaseIterable, Identifiable, Hashable, Codable {
    case claude
    case codex
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .opencode: return "AgentIcons/OpenCode"
        }
    }
}

// MARK: - Session entry

struct PullRequestLink: Hashable {
    let number: Int
    let url: String
    let repository: String?
}

/// Agent-specific fields used to build the resume command with appropriate flags.
enum AgentSpecifics: Hashable {
    case claude(model: String?, permissionMode: String?)
    case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
    case opencode(providerModel: String?, agentName: String?)
}

struct SessionEntry: Identifiable, Hashable {
    let id: String
    let agent: SessionAgent
    /// Native session identifier for the agent's CLI (used to build the resume command).
    let sessionId: String
    let title: String
    let cwd: String?
    let gitBranch: String?
    let pullRequest: PullRequestLink?
    let modified: Date
    let fileURL: URL?
    let specifics: AgentSpecifics

    /// Shell command that resumes this session in a new terminal, with the agent's
    /// known per-session settings injected as CLI flags.
    var resumeCommand: String {
        switch specifics {
        case let .claude(model, permissionMode):
            var parts = ["claude --resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("--model \(Self.shellQuote(model))")
            }
            if let permissionMode, !permissionMode.isEmpty {
                parts.append("--permission-mode \(Self.shellQuote(permissionMode))")
            }
            return parts.joined(separator: " ")
        case let .codex(model, approval, sandbox, effort):
            var parts = ["codex resume \(sessionId)"]
            if let model, !model.isEmpty {
                parts.append("-m \(Self.shellQuote(model))")
            }
            if let approval, !approval.isEmpty {
                parts.append("-a \(Self.shellQuote(approval))")
            }
            if let sandbox, !sandbox.isEmpty {
                parts.append("-s \(Self.shellQuote(sandbox))")
            }
            if let effort, !effort.isEmpty {
                parts.append("-c model_reasoning_effort=\(Self.shellQuote(effort))")
            }
            return parts.joined(separator: " ")
        case let .opencode(providerModel, agentName):
            var parts = ["opencode --session \(sessionId)"]
            if let providerModel, !providerModel.isEmpty {
                parts.append("-m \(Self.shellQuote(providerModel))")
            }
            if let agentName, !agentName.isEmpty {
                parts.append("--agent \(Self.shellQuote(agentName))")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Single-quote a value for safe shell injection. Escapes embedded single quotes.
    private static func shellQuote(_ value: String) -> String {
        if value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "sessionIndex.untitled", defaultValue: "Untitled session")
        }
        return trimmed
    }

    var cwdLabel: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        // Compare on a path boundary so /Users/al doesn't get matched by a
        // home of /Users/alice (would render as "~ice/foo").
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    var cwdBasename: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Parsed metadata cache

/// Process-wide cache for parsed Claude session metadata, keyed by file URL with
/// mtime as the freshness check. Avoids re-reading and re-parsing the same
/// jsonls across pagination calls. Bounded by `maxEntries` to keep memory in
/// check (LRU on insert).
final class ClaudeMetadataCache: @unchecked Sendable {
    static let shared = ClaudeMetadataCache()
    private let maxEntries = 1000
    private let lock = NSLock()
    private var entries: [URL: (mtime: Date, entry: SessionEntry)] = [:]

    func get(url: URL, mtime: Date) -> SessionEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entries[url], cached.mtime == mtime else { return nil }
        return cached.entry
    }

    func put(url: URL, mtime: Date, entry: SessionEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = (mtime, entry)
        if entries.count > maxEntries {
            // Evict ~10% (oldest mtimes) to amortize cleanup cost.
            let evictCount = entries.count / 10
            let oldestKeys = entries
                .sorted { $0.value.mtime < $1.value.mtime }
                .prefix(evictCount)
                .map(\.key)
            for k in oldestKeys { entries.removeValue(forKey: k) }
        }
    }
}

// MARK: - Drag registry

/// Process-wide registry that pairs a synthetic drag UUID with a SessionEntry.
/// Used to forward sessions through bonsplit's external-tab-drop hook (which only
/// carries UUIDs in its payload). Workspace.handleExternalTabDrop consults this
/// to decide whether a drop should spawn a brand new terminal vs. move an existing tab.
final class SessionDragRegistry {
    static let shared = SessionDragRegistry()

    private let lock = NSLock()
    private var pending: [UUID: SessionEntry] = [:]

    func register(_ entry: SessionEntry) -> UUID {
        let id = UUID()
        lock.lock()
        pending[id] = entry
        lock.unlock()
        // Auto-expire so a cancelled drag doesn't leak forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.lock.lock()
            self?.pending.removeValue(forKey: id)
            self?.lock.unlock()
        }
        return id
    }

    func consume(id: UUID) -> SessionEntry? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }
}

// MARK: - Store

enum SessionGrouping: String, CaseIterable, Identifiable, Codable {
    case directory
    case agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .directory: return String(localized: "sessionIndex.group.directory", defaultValue: "By folder")
        case .agent: return String(localized: "sessionIndex.group.agent", defaultValue: "By agent")
        }
    }

    var symbolName: String {
        switch self {
        case .directory: return "folder"
        case .agent: return "person.2"
        }
    }
}

/// Identifier for a section in the index. For agent grouping, raw value is `agent:<rawValue>`;
/// for directory grouping, `dir:<absolute path>` (or `dir:` for unknown).
struct SectionKey: Hashable {
    let raw: String

    static func agent(_ a: SessionAgent) -> SectionKey { SectionKey(raw: "agent:" + a.rawValue) }
    static func directory(_ path: String?) -> SectionKey { SectionKey(raw: "dir:" + (path ?? "")) }
}

struct IndexSection: Identifiable, Equatable {
    let key: SectionKey
    let title: String
    let icon: SectionIcon
    let entries: [SessionEntry]

    var id: SectionKey { key }
}

enum SectionIcon: Equatable {
    case agent(SessionAgent)
    case folder
}

/// Owns the "which section is currently being dragged" bit, separate from
/// `SessionIndexStore`. Isolating this means drag start/end does not emit
/// `objectWillChange` on the data store, so rows and gaps don't re-render
/// every time a drag begins or clears.
@MainActor
final class SessionDragCoordinator: ObservableObject {
    @Published var draggedKey: SectionKey? = nil
}

/// Immutable per-directory snapshot consumed by `SectionPopoverView` for
/// empty-query scrolling. All entries are merged across the three agent
/// sources and sorted by `modified` desc. The popover slices this array
/// in-memory to page, so scrolling fires zero store/disk calls.
struct DirectorySnapshot: Sendable {
    let cwd: String  // "" represents the unknown-folder bucket
    let entries: [SessionEntry]
    let errors: [String]
}

@MainActor
final class SessionIndexStore: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            invalidateSectionsCache()
        }
    }
    @Published private(set) var isLoading: Bool = false
    @Published var scopeToCurrentDirectory: Bool = false {
        didSet {
            guard scopeToCurrentDirectory != oldValue else { return }
            invalidateSectionsCache()
        }
    }
    @Published var currentDirectory: String? = nil {
        didSet {
            guard scopeToCurrentDirectory, currentDirectory != oldValue else { return }
            invalidateSectionsCache()
        }
    }

    func setCurrentDirectoryIfChanged(_ next: String?) {
        guard currentDirectory != next else { return }
        currentDirectory = next
    }

    @Published var grouping: SessionGrouping {
        didSet {
            guard grouping != oldValue else { return }
            UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey)
            invalidateSectionsCache()
            // Switching into directory grouping can expose cwds that were never
            // backfilled while the user was viewing agent grouping.
            if grouping == .directory { backfillDirectoryOrderFromEntries() }
        }
    }

    /// Persisted order for agent sections.
    @Published var agentOrder: [SessionAgent] {
        didSet {
            guard agentOrder != oldValue else { return }
            Self.persistAgentOrder(agentOrder)
            invalidateSectionsCache()
        }
    }

    /// Persisted order for directory sections (absolute paths; "" means "no folder").
    @Published var directoryOrder: [String] {
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
            sections = agentOrder.map { agent in
                IndexSection(
                    key: .agent(agent),
                    title: agent.displayName,
                    icon: .agent(agent),
                    entries: visible.filter { $0.agent == agent }
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
    /// already tracked. Kept out of the view-body path: it mutates `@Published`
    /// state and must only run in response to real data changes (new scan
    /// results, grouping switch) — not on every SwiftUI update tick.
    private func backfillDirectoryOrderFromEntries() {
        var seen = Set(directoryOrder)
        var additions: [(path: String, latest: Date)] = []
        for entry in entries {
            let path = entry.cwd ?? ""
            if seen.insert(path).inserted {
                additions.append((path, entry.modified))
            } else if let idx = additions.firstIndex(where: { $0.path == path }),
                      additions[idx].latest < entry.modified {
                additions[idx].latest = entry.modified
            }
        }
        guard !additions.isEmpty else { return }
        additions.sort { $0.latest > $1.latest }
        directoryOrder.append(contentsOf: additions.map(\.path))
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
            guard let oldIndex = agentOrder.firstIndex(of: agent) else { return }
            var next = agentOrder
            next.remove(at: oldIndex)
            if let referenceKey,
               referenceKey.raw.hasPrefix("agent:"),
               let refAgent = SessionAgent(rawValue: String(referenceKey.raw.dropFirst("agent:".count))),
               let refIndex = next.firstIndex(of: refAgent) {
                next.insert(agent, at: refIndex)
            } else {
                next.append(agent)
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
        for agent in SessionAgent.allCases where !ordered.contains(agent) {
            ordered.append(agent)
        }
        var seen = Set<SessionAgent>()
        ordered = ordered.filter { seen.insert($0).inserted }
        return ordered
    }

    private static func loadDirectoryOrder() -> [String] {
        UserDefaults.standard.array(forKey: directoryOrderDefaultsKey) as? [String] ?? []
    }

    private static func persistAgentOrder(_ order: [SessionAgent]) {
        UserDefaults.standard.set(order.map { $0.rawValue }, forKey: agentOrderDefaultsKey)
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
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = await Self.scanAll()
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                self.entries = scanned
                self.isLoading = false
                self.backfillDirectoryOrderFromEntries()
            }
        }
    }

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
        async let c = Self.timedAgent(
            needle: "", agent: .claude, cwdFilter: cwdFilter,
            offset: 0, limit: bigLimit, errorBag: bag
        )
        async let x = Self.timedAgent(
            needle: "", agent: .codex, cwdFilter: cwdFilter,
            offset: 0, limit: bigLimit, errorBag: bag
        )
        async let o = Self.timedAgent(
            needle: "", agent: .opencode, cwdFilter: cwdFilter,
            offset: 0, limit: bigLimit, errorBag: bag
        )
        var merged = (await c) + (await x) + (await o)
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
    private static let headByteCap = 64 * 1024
    private static let tailByteCap = 32 * 1024
    /// Hard cap on candidate files inspected per call to keep deep-page searches bounded.
    private static let searchMaxFiles = 1500

    private static func scanAll() async -> [SessionEntry] {
        // Initial scan errors are silently ignored — UI just shows the cached
        // entries we did get. Errors get surfaced when the user actively
        // searches via the popover.
        let bag = ErrorBag()
        async let claude = loadClaudeEntries(needle: "", cwdFilter: nil, offset: 0, limit: perAgentLimit)
        async let codex = loadCodexEntries(needle: "", cwdFilter: nil, offset: 0, limit: perAgentLimit, errorBag: bag)
        async let opencode = loadOpenCodeEntries(needle: "", cwdFilter: nil, offset: 0, limit: perAgentLimit, errorBag: bag)
        let combined = await claude + codex + opencode
        return combined.sorted { $0.modified > $1.modified }
    }

    private struct ClaudeParsed {
        var title: String = ""
        var cwd: String?
        var branch: String?
        var pr: PullRequestLink?
        var model: String?
        var permissionMode: String?
    }

    nonisolated private static func extractClaudeMetadata(head: String, tail: String, projectDir: String) -> ClaudeParsed {
        var out = ClaudeParsed()
        out.cwd = decodeClaudeProjectDir(projectDir)

        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let cwdField = obj["cwd"] as? String, !cwdField.isEmpty {
                out.cwd = cwdField
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
            if out.title.isEmpty,
               (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                if let content = message["content"] as? String, !content.isEmpty {
                    out.title = content
                } else if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if (part["type"] as? String) == "text",
                           let text = part["text"] as? String, !text.isEmpty {
                            out.title = text
                            break
                        }
                    }
                }
            }
        }

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "pr-link", let number = obj["prNumber"] as? Int,
               let url = obj["prUrl"] as? String {
                out.pr = PullRequestLink(
                    number: number,
                    url: url,
                    repository: obj["prRepository"] as? String
                )
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
        }
        // Strip the [1m] suffix some Claude internal model IDs carry (claude-opus-4-7[1m]).
        if let m = out.model, let bracket = m.firstIndex(of: "[") {
            out.model = String(m[..<bracket])
        }
        return out
    }

    /// Returns a usable user-prompt string from a Codex `user_message` /
    /// `response_item.input_text` payload, or nil when the message is just an
    /// envelope/system wrapper (`<environment_context>...`, `<user_instructions>`,
    /// `<permissions>`, AGENTS.md preamble) that we don't want to surface as a
    /// session title.
    nonisolated private static func realCodexUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let envelopePrefixes = [
            "<environment_context",
            "<user_instructions",
            "<permissions",
            "<system",
            "# AGENTS.md",
        ]
        for prefix in envelopePrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }

    nonisolated private static func decodeClaudeProjectDir(_ raw: String) -> String? {
        // Claude encodes cwd by replacing "/" with "-" and prefixing "-"
        // e.g. "-Users-lawrence-fun-cmuxterm-hq" -> "/Users/lawrence/fun/cmuxterm-hq".
        // The encoding is lossy: a real path segment containing "-"
        // (e.g. "my-cool-project") collapses to multiple segments
        // ("/my/cool/project") on decode, which is wrong. Only return the
        // candidate if it actually exists on disk; otherwise let the caller
        // fall back to the JSONL `cwd` field.
        guard !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        let candidate = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return candidate
    }

    /// Inverse of `decodeClaudeProjectDir`. Used as a fast path: when filtering
    /// by cwd we can skip enumerating other project dirs entirely.
    nonisolated private static func encodeClaudeProjectDir(_ path: String) -> String {
        // "/Users/x/y" -> "-Users-x-y"
        return path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Codex

    private struct CodexParsed {
        var sessionId: String = ""
        /// First user message — used only if Codex never assigns a thread_name.
        var firstUserMessage: String = ""
        /// Codex-generated session title (`event_msg.thread_name_updated`). Wins over firstUserMessage.
        var threadName: String = ""
        var cwd: String?
        var branch: String?
        var model: String?
        var approvalPolicy: String?
        var sandboxMode: String?
        var effort: String?

        var title: String {
            threadName.isEmpty ? firstUserMessage : threadName
        }
    }

    /// Cheap cwd peek for Codex rollouts. `session_meta` is always the first line
    /// of the file, but the line itself can be 30+ KB (it embeds the full system
    /// prompt). Read up to 64 KB to cover that, parse the JSON, return cwd.
    nonisolated private static func peekCodexSessionMetaCwd(url: URL) -> String? {
        let head = readFileHead(url: url, byteCap: headByteCap)
        guard let nl = head.firstIndex(of: "\n") else { return nil }
        let firstLine = head[..<nl]
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// Stream lines from `url` until we have everything we need. The first user_message
    /// can sit ~100 KB into a Codex rollout (after huge base_instructions + AGENTS.md),
    /// so a fixed head buffer is unreliable.
    nonisolated private static func extractCodexMetadata(url: URL) -> CodexParsed {
        var out = CodexParsed()
        let maxBytes = 4 * 1024 * 1024
        forEachJSONLine(url: url, maxBytes: maxBytes) { obj in
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                if let c = p["cwd"] as? String, !c.isEmpty { out.cwd = c }
                if let id = p["id"] as? String, !id.isEmpty { out.sessionId = id }
                if let git = p["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty {
                    out.branch = branch
                }
            }
            if type == "turn_context", let p = payload {
                if let m = p["model"] as? String, !m.isEmpty { out.model = m }
                if let a = p["approval_policy"] as? String, !a.isEmpty { out.approvalPolicy = a }
                if let sandbox = p["sandbox_policy"] as? [String: Any],
                   let s = sandbox["type"] as? String, !s.isEmpty {
                    out.sandboxMode = s
                }
                if let e = p["effort"] as? String, !e.isEmpty { out.effort = e }
            }
            if type == "event_msg", let p = payload,
               (p["type"] as? String) == "thread_name_updated",
               let name = p["thread_name"] as? String, !name.isEmpty {
                out.threadName = name
            }
            if out.firstUserMessage.isEmpty, type == "event_msg", let p = payload,
               (p["type"] as? String) == "user_message",
               let msg = p["message"] as? String,
               let real = realCodexUserMessage(msg) {
                out.firstUserMessage = real
            }
            if out.firstUserMessage.isEmpty, type == "response_item", let p = payload,
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user",
               let content = p["content"] as? [[String: Any]] {
                for part in content {
                    guard (part["type"] as? String) == "input_text",
                          let text = part["text"] as? String,
                          let real = realCodexUserMessage(text) else { continue }
                    out.firstUserMessage = real
                    break
                }
            }
            // Stop early once we have a real thread name + the launch metadata. If no
            // thread name appears we keep streaming until we at least have a user
            // message — Codex emits thread_name_updated late in newer versions but it's
            // still typically within the first few KB of events.
            return !out.threadName.isEmpty
                && out.cwd != nil
                && out.branch != nil
                && !out.sessionId.isEmpty
                && out.model != nil
        }
        return out
    }

    /// Stream JSON-lines from the start of `url`. `body` returns true to stop early.
    /// Caps total bytes read at `maxBytes`.
    nonisolated private static func forEachJSONLine(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024
        while totalRead < maxBytes {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: 0..<nl)
                leftover.removeSubrange(0..<(nl + 1))
                if lineData.isEmpty { continue }
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    if body(obj) { return }
                }
            }
        }
        // Flush trailing line if no newline at EOF.
        if !leftover.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: leftover) as? [String: Any] {
            _ = body(obj)
        }
    }

    // MARK: OpenCode

    nonisolated private static func parseOpenCodeAssistant(_ raw: String?) -> (String?, String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let modelID = obj["modelID"] as? String
        let providerID = obj["providerID"] as? String
        let agentName = obj["agent"] as? String
        let providerModel: String? = {
            switch (providerID, modelID) {
            case let (p?, m?) where !p.isEmpty && !m.isEmpty: return "\(p)/\(m)"
            case let (_, m?) where !m.isEmpty: return m
            default: return nil
            }
        }()
        return (providerModel, agentName?.isEmpty == false ? agentName : nil)
    }

    nonisolated private static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    nonisolated private static func sqliteMessage(_ db: OpaquePointer?) -> String? {
        guard let db, let cString = sqlite3_errmsg(db) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Deep search (popover "Show more")

    enum SearchScope {
        case agent(SessionAgent)
        /// Filter by absolute cwd; nil/"" = unknown-folder bucket.
        case directory(String?)
    }

    /// What the popover gets back. `errors` is non-empty when one or more
    /// agents failed to read their data source (schema mismatch, file missing,
    /// SQL error). UI should surface them so users see why the list looks
    /// short or empty rather than thinking nothing matched.
    struct SearchOutcome: Sendable {
        var entries: [SessionEntry]
        var errors: [String]
    }

    /// Thread-safe accumulator passed down to per-agent helpers so they can
    /// report failures (e.g. SQL prepare errors when an agent bumps its
    /// schema) without requiring the helpers to throw across actor boundaries.
    final class ErrorBag: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ msg: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append(msg)
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
    }

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
            dlog("session.search.total ms=\(String(format: "%.0f", totalMs)) needle=\"\(trimmed.prefix(20))\" offset=\(offset) limit=\(limit) errors=\(bag.snapshot().count)")
        }
        #endif
        let entries: [SessionEntry]
        switch scope {
        case .agent(let a):
            entries = await Self.searchAgent(
                needle: needle, agent: a, cwdFilter: nil,
                offset: offset, limit: limit, errorBag: bag
            )
        case .directory(let path):
            let cwdFilter = (path?.isEmpty == false) ? path : nil
            // Multi-agent merge: fetch the union of (offset+limit) per agent so the
            // merge-sort can produce a stable global ordering, then slice.
            let target = offset + limit
            async let c = Self.timedAgent(
                needle: needle, agent: .claude, cwdFilter: cwdFilter,
                offset: 0, limit: target, errorBag: bag
            )
            async let x = Self.timedAgent(
                needle: needle, agent: .codex, cwdFilter: cwdFilter,
                offset: 0, limit: target, errorBag: bag
            )
            async let o = Self.timedAgent(
                needle: needle, agent: .opencode, cwdFilter: cwdFilter,
                offset: 0, limit: target, errorBag: bag
            )
            let merged = (await c) + (await x) + (await o)
            let sorted = merged.sorted { $0.modified > $1.modified }
            entries = Array(sorted.dropFirst(offset).prefix(limit))
        }
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }

    nonisolated private static func timedAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag
    ) async -> [SessionEntry] {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let result = await searchAgent(needle: needle, agent: agent, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        dlog("session.search.agent agent=\(agent.rawValue) ms=\(String(format: "%.0f", ms)) results=\(result.count) cwd=\(cwdFilter?.suffix(40) ?? "nil")")
        return result
        #else
        return await searchAgent(needle: needle, agent: agent, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        #endif
    }

    nonisolated private static func searchAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag
    ) async -> [SessionEntry] {
        switch agent {
        case .claude: return await loadClaudeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
        case .codex: return await loadCodexEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .opencode: return loadOpenCodeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        }
    }

    /// Path to `rg` (ripgrep), if installed. Resolved once. nil when not found —
    /// the search code falls back to the Foundation substring scan.
    nonisolated private static let cachedRipgrepPath: String? = {
        let fm = FileManager.default
        let common = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            "/opt/local/bin/rg",
        ]
        for path in common where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = String(dir) + "/rg"
                if fm.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }()

    /// Run `rg --files-with-matches --ignore-case --fixed-strings` for `needle`
    /// under `root`, restricted to `glob` (e.g. `*.jsonl`). Returns matched file
    /// URLs, or nil if rg isn't available or the run failed (caller falls back).
    ///
    /// Async by design so we can wire cancellation: when the awaiting Task is
    /// cancelled (e.g. user types another key), `onCancel` calls
    /// `process.terminate()`, killing the in-flight rg instead of letting it
    /// grind to completion. Wait is also async (via `terminationHandler`) so we
    /// don't tie up a cooperative-pool thread on `waitUntilExit`.
    nonisolated private static func ripgrepMatchingPaths(
        needle: String, root: String, fileGlob: String
    ) async -> [URL]? {
        guard let rg = cachedRipgrepPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = [
            "--files-with-matches",
            "--ignore-case",
            "--fixed-strings",
            "--no-messages",
            "--no-ignore",
            "--hidden",
            "--glob", fileGlob,
            "--",
            needle,
            root,
        ]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr to /dev/null so its pipe can never deadlock either.
        if let nullDev = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullDev
        }

        return await withTaskCancellationHandler {
            do { try process.run() } catch { return nil as [URL]? }
            // Drain stdout BEFORE waitUntilExit. With many matches rg writes
            // more than the ~64 KB pipe buffer; reading until EOF lets rg
            // make progress and EOF arrives when rg closes its stdout on exit.
            // Once readDataToEndOfFile returns, the process is already exiting,
            // so waitUntilExit is essentially instant — we just need it to make
            // terminationStatus observable. (Setting terminationHandler here
            // would race: if rg already exited, the handler is registered too
            // late and never fires → deadlock.)
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // rg exit codes: 0 = matches, 1 = no matches, 2 = error/terminated.
            switch process.terminationStatus {
            case 0:
                guard let str = String(data: data, encoding: .utf8) else { return nil as [URL]? }
                return str.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { URL(fileURLWithPath: String($0)) }
            case 1:
                return []
            default:
                return nil
            }
        } onCancel: {
            // Fires synchronously when the awaiting Task is cancelled. Sends
            // SIGTERM to rg, which closes stdout, lets readDataToEndOfFile
            // return, and unblocks the body so this call can complete cleanly.
            process.terminate()
        }
    }

    /// Returns Claude session entries paginated by mtime desc.
    /// - When `needle` is empty: fast path. Skips rg, enumerates `~/.claude/projects`,
    ///   takes the top `offset+limit` by mtime, parses metadata, returns the slice.
    /// - When `needle` is non-empty and rg is on PATH: rg pre-filters the candidate
    ///   set; we only parse files that actually contain the needle.
    /// - When `needle` is non-empty and rg is missing/failed: falls back to the
    ///   Foundation enumeration + 64 KB head + 32 KB tail substring scan.
    nonisolated private static func loadClaudeEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) async -> [SessionEntry] {
        let projectsRoot = ("~/.claude/projects" as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Pre-filter via rg when we have a needle — rg is parallel, mmaps the
        // file, and scans the WHOLE file (not just our 128 KB head), so it both
        // speeds the scan up and finds matches deeper in long transcripts.
        var rgFiltered = false
        var candidates: [(URL, Date, String)] = []
        if !needle.isEmpty,
           let rgPaths = await ripgrepMatchingPaths(needle: needle, root: projectsRoot, fileGlob: "*.jsonl") {
            rgFiltered = true
            for url in rgPaths {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let dirName = url.deletingLastPathComponent().lastPathComponent
                candidates.append((url, mtime, dirName))
            }
        } else if let cwdFilter {
            // Fast path: the project directory name encodes the cwd. We can skip
            // enumerating every other project entirely.
            let dirName = encodeClaudeProjectDir(cwdFilter)
            let dirPath = (projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue,
               let contents = try? fm.contentsOfDirectory(atPath: dirPath) {
                for name in contents where name.hasSuffix(".jsonl") {
                    let filePath = (dirPath as NSString).appendingPathComponent(name)
                    let url = URL(fileURLWithPath: filePath)
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    candidates.append((url, mtime, dirName))
                }
            }
        } else {
            guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }
            for dirName in projectDirs {
                let dirPath = (projectsRoot as NSString).appendingPathComponent(dirName)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in contents where name.hasSuffix(".jsonl") {
                    let filePath = (dirPath as NSString).appendingPathComponent(name)
                    let url = URL(fileURLWithPath: filePath)
                    guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    candidates.append((url, mtime, dirName))
                }
            }
        }
        candidates.sort { $0.1 > $1.1 }

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
                let (url, mtime, dirName) = candidate
                group.addTask {
                    // Cache hit
                    if let cached = ClaudeMetadataCache.shared.get(url: url, mtime: mtime) {
                        if let cwdFilter, cached.cwd != cwdFilter { return (idx, nil, true) }
                        return (idx, cached, true)
                    }
                    let head = readFileHead(url: url, byteCap: headByteCap)
                    let tail = readFileTail(url: url, byteCap: tailByteCap)
                    if !needle.isEmpty && !rgFiltered {
                        let combined = head + "\n" + tail
                        if combined.range(of: needle, options: [.caseInsensitive, .literal]) == nil {
                            return (idx, nil, false)
                        }
                    }
                    let parsed = extractClaudeMetadata(head: head, tail: tail, projectDir: dirName)
                    if let cwdFilter, parsed.cwd != cwdFilter { return (idx, nil, false) }
                    let sid = url.deletingPathExtension().lastPathComponent
                    let entry = SessionEntry(
                        id: "claude:" + url.path,
                        agent: .claude,
                        sessionId: sid,
                        title: parsed.title,
                        cwd: parsed.cwd,
                        gitBranch: parsed.branch,
                        pullRequest: parsed.pr,
                        modified: mtime,
                        fileURL: url,
                        specifics: .claude(model: parsed.model, permissionMode: parsed.permissionMode)
                    )
                    if needle.isEmpty {
                        ClaudeMetadataCache.shared.put(url: url, mtime: mtime, entry: entry)
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
        dlog("session.claude.detail target=\(target) workSize=\(workSize) matched=\(matched.count) cachedHits=\(cachedCount) skipped=\(skippedCount) parallelMs=\(Int(totalMs))")
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
        if let viaSQL = loadCodexEntriesViaSQL(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit,
            errorBag: errorBag
        ) {
            return viaSQL
        }
        return await loadCodexEntriesFromDisk(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit
        )
    }

    /// SQL-backed Codex loader. Returns nil if `state_5.sqlite` doesn't exist
    /// (signaling caller to fall back to the disk scan). On schema mismatch or
    /// other SQL errors, appends a user-facing message to `errorBag` and still
    /// returns nil so the caller can fall back.
    nonisolated private static func loadCodexEntriesViaSQL(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag
    ) -> [SessionEntry]? {
        let dbPath = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return nil }

        // Snapshot DB + WAL/SHM to avoid contention with a running Codex.
        let snapshotDir = fm.temporaryDirectory.appendingPathComponent(
            "cmux-codex-search-\(UUID().uuidString)", isDirectory: true
        )
        do { try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true) } catch { return nil }
        defer { try? fm.removeItem(at: snapshotDir) }
        let snapshotDB = snapshotDir.appendingPathComponent("state.db")
        do { try fm.copyItem(atPath: dbPath, toPath: snapshotDB.path) } catch { return nil }
        for sidecar in ["-wal", "-shm"] {
            let src = dbPath + sidecar
            let dst = snapshotDB.path + sidecar
            if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: dst) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshotDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            errorBag.add("Codex: cannot open state_5.sqlite (\(sqliteMessage(db) ?? "unknown error"))")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var sql = """
            SELECT id, rollout_path, cwd, title, model, git_branch,
                   approval_mode, sandbox_policy, reasoning_effort,
                   first_user_message, updated_at_ms
            FROM threads
            WHERE archived = 0
            """
        var conditions: [String] = []
        if !needle.isEmpty {
            // Match against title, first_user_message, cwd, and git_branch.
            conditions.append("(LOWER(title) LIKE ?1 OR LOWER(first_user_message) LIKE ?1 OR LOWER(cwd) LIKE ?1 OR LOWER(git_branch) LIKE ?1)")
        }
        if cwdFilter != nil {
            conditions.append("cwd = ?\(needle.isEmpty ? 1 : 2)")
        }
        if !conditions.isEmpty {
            sql += " AND " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY updated_at_ms DESC LIMIT \(limit) OFFSET \(offset)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            errorBag.add("Codex: schema unsupported — \(sqliteMessage(db) ?? "prepare failed"). Falling back to file scan.")
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        if !needle.isEmpty {
            sqlite3_bind_text(stmt, 1, "%\(needle)%", -1, SQLITE_TRANSIENT_FN)
        }
        if let cwdFilter {
            sqlite3_bind_text(stmt, needle.isEmpty ? 1 : 2, cwdFilter, -1, SQLITE_TRANSIENT_FN)
        }

        var results: [SessionEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = sqliteText(stmt, 0) ?? ""
            let rollout = sqliteText(stmt, 1) ?? ""
            let cwd = sqliteText(stmt, 2)
            let titleField = sqliteText(stmt, 3) ?? ""
            let model = sqliteText(stmt, 4)
            let branch = sqliteText(stmt, 5)
            let approval = sqliteText(stmt, 6)
            let sandboxJSON = sqliteText(stmt, 7)
            let effort = sqliteText(stmt, 8)
            let firstMsg = sqliteText(stmt, 9) ?? ""
            let updatedMs = sqlite3_column_int64(stmt, 10)
            let modified = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)

            // Codex stores sandbox_policy as JSON like {"type":"danger-full-access"}.
            let sandboxMode = sandboxJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["type"] as? String }

            // Prefer Codex's curated `title`. Fall back to first_user_message,
            // skipping envelope wrappers (<environment_context>, etc.).
            let displayTitle: String
            if !titleField.isEmpty {
                displayTitle = titleField
            } else if let real = realCodexUserMessage(firstMsg) {
                displayTitle = real
            } else {
                displayTitle = ""
            }

            let fileURL: URL? = rollout.isEmpty ? nil : URL(fileURLWithPath: rollout)
            results.append(SessionEntry(
                id: "codex:" + (fileURL?.path ?? sid),
                agent: .codex,
                sessionId: sid,
                title: displayTitle,
                cwd: cwd,
                gitBranch: branch?.isEmpty == false ? branch : nil,
                pullRequest: nil,
                modified: modified,
                fileURL: fileURL,
                specifics: .codex(
                    model: model?.isEmpty == false ? model : nil,
                    approvalPolicy: approval?.isEmpty == false ? approval : nil,
                    sandboxMode: sandboxMode,
                    effort: effort?.isEmpty == false ? effort : nil
                )
            ))
        }
        return results
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
           let rgPaths = await ripgrepMatchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") {
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
                let head = readFileHead(url: url, byteCap: headByteCap)
                guard head.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }
            // Fast cwd reject: session_meta is the FIRST line of every Codex
            // rollout. Pull just that line and bail before streaming the
            // (potentially MB-sized) rest of the file looking for title/branch.
            if let cwdFilter,
               let firstLineCwd = peekCodexSessionMetaCwd(url: url),
               firstLineCwd != cwdFilter {
                continue
            }
            let parsed = extractCodexMetadata(url: url)
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
        let dbPath = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return [] }
        let snapshotDir = fm.temporaryDirectory.appendingPathComponent("cmux-opencode-search-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true) } catch { return [] }
        defer { try? fm.removeItem(at: snapshotDir) }
        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db")
        do { try fm.copyItem(atPath: dbPath, toPath: snapshotDB.path) } catch { return [] }
        for sidecar in ["-wal", "-shm"] {
            let src = dbPath + sidecar
            let dst = snapshotDB.path + sidecar
            if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: dst) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshotDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            errorBag.add("OpenCode: cannot open opencode.db (\(sqliteMessage(db) ?? "unknown error"))")
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
            errorBag.add("OpenCode: schema unsupported — \(sqliteMessage(db) ?? "prepare failed")")
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
            let sid = sqliteText(stmt, 0) ?? ""
            let title = sqliteText(stmt, 1) ?? ""
            let directory = sqliteText(stmt, 2)
            let updatedMs = sqlite3_column_int64(stmt, 3)
            let modified = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
            let lastJSON = sqliteText(stmt, 4)
            let (providerModel, agentName) = parseOpenCodeAssistant(lastJSON)
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

    /// Read up to `byteCap` bytes from the start of the file as UTF-8.
    nonisolated private static func readFileHead(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Read up to `byteCap` bytes from the end of the file as UTF-8.
    /// Used to find late-arriving events like pr-link without scanning the whole file.
    nonisolated private static func readFileTail(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return "" }
        if size == 0 { return "" }
        let cap = UInt64(byteCap)
        let offset: UInt64 = size > cap ? size - cap : 0
        do { try handle.seek(toOffset: offset) } catch { return "" }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        // Trim leading partial line (we likely cut mid-record).
        if offset > 0, let nl = data.firstIndex(of: 0x0a) {
            return String(data: data[(nl + 1)...], encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
