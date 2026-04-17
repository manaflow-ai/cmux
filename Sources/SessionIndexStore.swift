import AppKit
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
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    var cwdBasename: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
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

struct IndexSection: Identifiable {
    let key: SectionKey
    let title: String
    let icon: SectionIcon
    let entries: [SessionEntry]

    var id: SectionKey { key }
}

enum SectionIcon {
    case agent(SessionAgent)
    case folder
}

@MainActor
final class SessionIndexStore: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published var scopeToCurrentDirectory: Bool = false
    @Published var currentDirectory: String? = nil

    @Published var grouping: SessionGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey) }
    }

    /// Persisted order for agent sections.
    @Published var agentOrder: [SessionAgent] {
        didSet { Self.persistAgentOrder(agentOrder) }
    }

    /// Persisted order for directory sections (absolute paths; "" means "no folder").
    @Published var directoryOrder: [String] {
        didSet { Self.persistDirectoryOrder(directoryOrder) }
    }

    /// The section currently being dragged, if any. Drives "hide adjacent drop slots".
    @Published var draggedKey: SectionKey? = nil

    private static let groupingKey = "sessionIndex.grouping"
    private static let agentOrderDefaultsKey = "sessionIndex.agentOrder"
    private static let directoryOrderDefaultsKey = "sessionIndex.directoryOrder"

    init() {
        self.agentOrder = Self.loadAgentOrder()
        self.directoryOrder = Self.loadDirectoryOrder()
        let storedGrouping = UserDefaults.standard.string(forKey: Self.groupingKey)
        self.grouping = SessionGrouping(rawValue: storedGrouping ?? "") ?? .directory
    }

    /// Returns the sections for the current grouping mode, in the user-saved order.
    func sectionsForCurrentGrouping() -> [IndexSection] {
        let visible = filteredEntriesForCurrentScope()
        switch grouping {
        case .agent:
            return agentOrder.map { agent in
                IndexSection(
                    key: .agent(agent),
                    title: agent.displayName,
                    icon: .agent(agent),
                    entries: visible.filter { $0.agent == agent }
                )
            }
        case .directory:
            let buckets = Dictionary(grouping: visible) { $0.cwd ?? "" }
            // Discover any directories not yet in saved order; append by most-recent activity.
            let knownPaths = Set(directoryOrder)
            let unknownSorted = buckets.keys
                .filter { !knownPaths.contains($0) }
                .sorted { lhs, rhs in
                    let lMax = buckets[lhs]?.map(\.modified).max() ?? .distantPast
                    let rMax = buckets[rhs]?.map(\.modified).max() ?? .distantPast
                    return lMax > rMax
                }
            if !unknownSorted.isEmpty {
                let nextOrder = directoryOrder + unknownSorted
                Task { @MainActor in self.directoryOrder = nextOrder }
            }
            return (directoryOrder + unknownSorted)
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

    /// Insert `key` so that, after removing its old position, it lands at `insertIndex`.
    /// `insertIndex` is in the *post-removal* index space.
    func moveSection(_ key: SectionKey, toInsertIndex insertIndex: Int) {
        switch grouping {
        case .agent:
            guard key.raw.hasPrefix("agent:"),
                  let agent = SessionAgent(rawValue: String(key.raw.dropFirst("agent:".count))) else { return }
            guard let oldIndex = agentOrder.firstIndex(of: agent) else { return }
            var next = agentOrder
            next.remove(at: oldIndex)
            let target = max(0, min(insertIndex, next.count))
            if target == oldIndex { return }
            next.insert(agent, at: target)
            agentOrder = next
        case .directory:
            guard key.raw.hasPrefix("dir:") else { return }
            let path = String(key.raw.dropFirst("dir:".count))
            guard let oldIndex = directoryOrder.firstIndex(of: path) else { return }
            var next = directoryOrder
            next.remove(at: oldIndex)
            let target = max(0, min(insertIndex, next.count))
            if target == oldIndex { return }
            next.insert(path, at: target)
            directoryOrder = next
        }
    }

    /// Pre-removal index of the dragged key in the active grouping order, or nil if unknown.
    func currentIndex(of key: SectionKey) -> Int? {
        switch grouping {
        case .agent:
            guard key.raw.hasPrefix("agent:"),
                  let agent = SessionAgent(rawValue: String(key.raw.dropFirst("agent:".count))) else { return nil }
            return agentOrder.firstIndex(of: agent)
        case .directory:
            guard key.raw.hasPrefix("dir:") else { return nil }
            let path = String(key.raw.dropFirst("dir:".count))
            return directoryOrder.firstIndex(of: path)
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
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = await Self.scanAll()
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                self.entries = scanned
                self.isLoading = false
            }
        }
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
    /// Limits for the on-demand deep search (popover "Show more").
    private static let searchMaxResults = 200
    private static let searchMaxFiles = 1500
    private static let searchFileByteCap = 128 * 1024

    private static func scanAll() async -> [SessionEntry] {
        async let claude = scanClaude()
        async let codex = scanCodex()
        async let opencode = scanOpenCode()
        let combined = await claude + codex + opencode
        return combined.sorted { $0.modified > $1.modified }
    }

    // MARK: Claude

    private static func scanClaude() async -> [SessionEntry] {
        let projectsRoot = ("~/.claude/projects" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsRoot) else {
            return []
        }

        var candidates: [(URL, Date, String)] = []
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

        candidates.sort { $0.1 > $1.1 }
        let limited = candidates.prefix(perAgentLimit)

        var results: [SessionEntry] = []
        results.reserveCapacity(limited.count)
        for (url, mtime, dirName) in limited {
            let head = readFileHead(url: url, byteCap: headByteCap)
            let tail = readFileTail(url: url, byteCap: tailByteCap)
            let parsed = extractClaudeMetadata(head: head, tail: tail, projectDir: dirName)
            let sid = url.deletingPathExtension().lastPathComponent
            results.append(SessionEntry(
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
            ))
        }
        return results
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

    nonisolated private static func decodeClaudeProjectDir(_ raw: String) -> String? {
        // Claude encodes cwd by replacing "/" with "-" and prefixing "-"
        // e.g. "-Users-lawrence-fun-cmuxterm-hq" -> "/Users/lawrence/fun/cmuxterm-hq"
        // This is lossy (cannot distinguish original "-" from "/"), so try as a hint only.
        guard !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        let candidate = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        return candidate
    }

    // MARK: Codex

    private static func scanCodex() async -> [SessionEntry] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate else { continue }
            candidates.append((url, mtime))
        }
        candidates.sort { $0.1 > $1.1 }
        let limited = candidates.prefix(perAgentLimit)

        var results: [SessionEntry] = []
        results.reserveCapacity(limited.count)
        for (url, mtime) in limited {
            let parsed = extractCodexMetadata(url: url)
            results.append(SessionEntry(
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
        return results
    }

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
               let msg = p["message"] as? String, !msg.isEmpty {
                out.firstUserMessage = msg
            }
            if out.firstUserMessage.isEmpty, type == "response_item", let p = payload,
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user",
               let content = p["content"] as? [[String: Any]] {
                for part in content {
                    if (part["type"] as? String) == "input_text",
                       let text = part["text"] as? String,
                       !text.isEmpty,
                       !text.hasPrefix("# AGENTS.md"),
                       !text.hasPrefix("<user_instructions>"),
                       !text.hasPrefix("<permissions") {
                        out.firstUserMessage = text
                        break
                    }
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

    private static func scanOpenCode() async -> [SessionEntry] {
        let dbPath = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return [] }

        // Snapshot DB + WAL/SHM into a temp directory to avoid contention with a running OpenCode.
        let snapshotDir = fm.temporaryDirectory.appendingPathComponent("cmux-opencode-snap-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fm.removeItem(at: snapshotDir) }

        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db")
        do {
            try fm.copyItem(atPath: dbPath, toPath: snapshotDB.path)
        } catch {
            return []
        }
        for sidecar in ["-wal", "-shm"] {
            let src = dbPath + sidecar
            let dst = snapshotDB.path + sidecar
            if fm.fileExists(atPath: src) {
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }

        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(snapshotDB.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // Pull the latest assistant message per session in one query so we can carry
        // model + agent forward into the resume command.
        let sql = """
            SELECT s.id, s.title, s.directory, s.time_updated, (
                SELECT data FROM message
                WHERE session_id = s.id AND data LIKE '%"role":"assistant"%'
                ORDER BY time_created DESC LIMIT 1
            ) AS last_assistant
            FROM session s
            ORDER BY s.time_updated DESC
            LIMIT \(perAgentLimit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

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

    // MARK: - Deep search (popover "Show more")

    enum SearchScope {
        case agent(SessionAgent)
        /// Filter by absolute cwd; nil/"" = unknown-folder bucket.
        case directory(String?)
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
    ) async -> [SessionEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        return await Task.detached(priority: .userInitiated) {
            switch scope {
            case .agent(let a):
                return Self.searchAgent(
                    needle: needle, agent: a, cwdFilter: nil,
                    offset: offset, limit: limit
                )
            case .directory(let path):
                let cwdFilter = (path?.isEmpty == false) ? path : nil
                // Multi-agent merge: fetch the union of (offset+limit) per agent so the
                // merge-sort can produce a stable global ordering, then slice.
                let target = offset + limit
                async let c = Self.searchAgent(
                    needle: needle, agent: .claude, cwdFilter: cwdFilter,
                    offset: 0, limit: target
                )
                async let x = Self.searchAgent(
                    needle: needle, agent: .codex, cwdFilter: cwdFilter,
                    offset: 0, limit: target
                )
                async let o = Self.searchAgent(
                    needle: needle, agent: .opencode, cwdFilter: cwdFilter,
                    offset: 0, limit: target
                )
                let merged = (await c) + (await x) + (await o)
                let sorted = merged.sorted { $0.modified > $1.modified }
                return Array(sorted.dropFirst(offset).prefix(limit))
            }
        }.value
    }

    nonisolated private static func searchAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int
    ) -> [SessionEntry] {
        switch agent {
        case .claude: return searchClaudeOnDisk(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
        case .codex: return searchCodexOnDisk(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
        case .opencode: return searchOpenCodeInDB(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
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
    nonisolated private static func ripgrepMatchingPaths(
        needle: String, root: String, fileGlob: String
    ) -> [URL]? {
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
        do { try process.run() } catch { return nil }
        // Drain stdout BEFORE waitUntilExit. With many matches rg writes more
        // than the ~64 KB pipe buffer can hold, blocks on the next write, and
        // process.waitUntilExit() then deadlocks (rg can't exit until stdout
        // drains, we won't drain until rg exits). readDataToEndOfFile reads
        // until EOF (= rg closes its stdout when it finishes), so the order
        // matters: read, then wait.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // rg exit codes: 0 = matches, 1 = no matches, 2 = error.
        switch process.terminationStatus {
        case 0:
            guard let str = String(data: data, encoding: .utf8) else { return nil }
            return str.split(separator: "\n", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)) }
        case 1:
            return []
        default:
            return nil
        }
    }

    nonisolated private static func searchClaudeOnDisk(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) -> [SessionEntry] {
        let projectsRoot = ("~/.claude/projects" as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Pre-filter via rg when we have a needle — rg is parallel, mmaps the
        // file, and scans the WHOLE file (not just our 128 KB head), so it both
        // speeds the scan up and finds matches deeper in long transcripts.
        var rgFiltered = false
        var candidates: [(URL, Date, String)] = []
        if !needle.isEmpty,
           let rgPaths = ripgrepMatchingPaths(needle: needle, root: projectsRoot, fileGlob: "*.jsonl") {
            rgFiltered = true
            for url in rgPaths {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let dirName = url.deletingLastPathComponent().lastPathComponent
                candidates.append((url, mtime, dirName))
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

        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        for (url, mtime, dirName) in candidates {
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1
            let head = readFileHead(url: url, byteCap: searchFileByteCap)
            let tail = readFileTail(url: url, byteCap: tailByteCap)
            // Skip the substring re-check when rg already confirmed the file matches.
            if !needle.isEmpty && !rgFiltered {
                let combined = head + "\n" + tail
                guard combined.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }
            let parsed = extractClaudeMetadata(head: head, tail: tail, projectDir: dirName)
            if let cwdFilter, parsed.cwd != cwdFilter { continue }
            let sid = url.deletingPathExtension().lastPathComponent
            matches.append(SessionEntry(
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
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func searchCodexOnDisk(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) -> [SessionEntry] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        let fm = FileManager.default

        var rgFiltered = false
        var candidates: [(URL, Date)] = []
        if !needle.isEmpty,
           let rgPaths = ripgrepMatchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") {
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
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1
            if !needle.isEmpty && !rgFiltered {
                let head = readFileHead(url: url, byteCap: searchFileByteCap)
                guard head.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
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

    nonisolated private static func searchOpenCodeInDB(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
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
