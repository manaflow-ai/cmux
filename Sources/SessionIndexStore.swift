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

struct SessionEntry: Identifiable, Hashable {
    let id: String
    let agent: SessionAgent
    let title: String
    let cwd: String?
    let gitBranch: String?
    let pullRequest: PullRequestLink?
    let modified: Date
    let fileURL: URL?

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

// MARK: - Store

@MainActor
final class SessionIndexStore: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published var scopeToCurrentDirectory: Bool = false
    @Published var currentDirectory: String? = nil

    /// User-visible order of agent sections. Persisted across launches.
    @Published var agentOrder: [SessionAgent] {
        didSet { Self.persistOrder(agentOrder) }
    }

    /// The agent currently being dragged, if any. Drives "hide adjacent drop slots".
    @Published var draggedAgent: SessionAgent? = nil

    private static let agentOrderDefaultsKey = "sessionIndex.agentOrder"

    init() {
        self.agentOrder = Self.loadOrder()
    }

    /// Insert `agent` so that, after removal of its old position, it lands at `insertIndex`.
    /// `insertIndex` is in the *post-removal* index space (0...count-1).
    func moveAgent(_ agent: SessionAgent, toInsertIndex insertIndex: Int) {
        guard let oldIndex = agentOrder.firstIndex(of: agent) else { return }
        var next = agentOrder
        next.remove(at: oldIndex)
        let target = max(0, min(insertIndex, next.count))
        if target == oldIndex { return }
        next.insert(agent, at: target)
        agentOrder = next
    }

    private static func loadOrder() -> [SessionAgent] {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: agentOrderDefaultsKey) as? [String] ?? []
        var ordered: [SessionAgent] = stored.compactMap { SessionAgent(rawValue: $0) }
        for agent in SessionAgent.allCases where !ordered.contains(agent) {
            ordered.append(agent)
        }
        // Drop any duplicates while preserving first occurrence
        var seen = Set<SessionAgent>()
        ordered = ordered.filter { seen.insert($0).inserted }
        return ordered
    }

    private static func persistOrder(_ order: [SessionAgent]) {
        UserDefaults.standard.set(order.map { $0.rawValue }, forKey: agentOrderDefaultsKey)
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

    func filteredEntries(for agent: SessionAgent) -> [SessionEntry] {
        let base = entries.filter { $0.agent == agent }
        guard scopeToCurrentDirectory, let dir = normalizedDirectory(currentDirectory) else {
            return base
        }
        return base.filter { entry in
            guard let cwd = normalizedDirectory(entry.cwd) else { return false }
            return cwd == dir || cwd.hasPrefix(dir + "/")
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

    private static let perAgentLimit = 60
    private static let headByteCap = 64 * 1024
    private static let tailByteCap = 32 * 1024

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
            results.append(SessionEntry(
                id: "claude:" + url.path,
                agent: .claude,
                title: parsed.title,
                cwd: parsed.cwd,
                gitBranch: parsed.branch,
                pullRequest: parsed.pr,
                modified: mtime,
                fileURL: url
            ))
        }
        return results
    }

    private struct ClaudeParsed {
        var title: String = ""
        var cwd: String?
        var branch: String?
        var pr: PullRequestLink?
    }

    private static func extractClaudeMetadata(head: String, tail: String, projectDir: String) -> ClaudeParsed {
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
            if out.title.isEmpty == false && out.branch != nil { break }
        }

        // Tail scan: pr-link tends to live at end; also catches branch updates.
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
        }
        return out
    }

    private static func decodeClaudeProjectDir(_ raw: String) -> String? {
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
            let head = readFileHead(url: url, byteCap: headByteCap)
            let parsed = extractCodexMetadata(jsonl: head)
            results.append(SessionEntry(
                id: "codex:" + url.path,
                agent: .codex,
                title: parsed.title,
                cwd: parsed.cwd,
                gitBranch: parsed.branch,
                pullRequest: nil,
                modified: mtime,
                fileURL: url
            ))
        }
        return results
    }

    private struct CodexParsed {
        var title: String = ""
        var cwd: String?
        var branch: String?
    }

    private static func extractCodexMetadata(jsonl: String) -> CodexParsed {
        var out = CodexParsed()
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                if let c = p["cwd"] as? String, !c.isEmpty { out.cwd = c }
                if let git = p["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty {
                    out.branch = branch
                }
            }
            if out.title.isEmpty, type == "event_msg", let p = payload,
               (p["type"] as? String) == "user_message",
               let msg = p["message"] as? String, !msg.isEmpty {
                out.title = msg
            }
            if !out.title.isEmpty && out.cwd != nil && out.branch != nil { break }
        }
        return out
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

        let sql = "SELECT id, title, directory, time_updated FROM session ORDER BY time_updated DESC LIMIT \(perAgentLimit)"
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
            results.append(SessionEntry(
                id: "opencode:" + sid,
                agent: .opencode,
                title: title,
                cwd: directory,
                gitBranch: nil,
                pullRequest: nil,
                modified: modified,
                fileURL: nil
            ))
        }
        return results
    }

    private static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    // MARK: Helpers

    /// Read up to `byteCap` bytes from the start of the file as UTF-8.
    private static func readFileHead(url: URL, byteCap: Int) -> String {
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
    private static func readFileTail(url: URL, byteCap: Int) -> String {
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
