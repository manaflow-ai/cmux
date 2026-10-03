public import Foundation

/// Finds the projects behind the user's agent sessions, without asking:
/// each session file records its working directory.
///
/// - Claude Code: `~/.claude/projects/<slug>/*.jsonl`, a line's `cwd`.
/// - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, `session_meta.payload.cwd`.
/// - Pi: `~/.pi/agent/sessions/<slug>/*.jsonl`, the `session` header's `cwd`.
/// - OpenCode: `~/.local/share/opencode/storage/session/<project>/*.json`, `directory`.
///
/// Gemini CLI keeps only a hash of the folder, so it names none.
///
/// Folders are grouped and ranked by recency and session count. The home
/// folder, temporary folders and folders that are gone are left out. A
/// folder under Desktop, Documents, Downloads or iCloud Drive is kept
/// without being looked at, since looking would raise a macOS privacy
/// prompt mid-scan. Reading the agents' own folders raises none.
public nonisolated struct AgentProjectScan: Sendable {
    public var home: URL
    public var claude: URL
    public var codex: URL
    public var pi: URL
    public var opencode: URL
    /// The newest session files read per app; older ones add nothing a user would pick.
    public var filesPerApp = 2000

    public init(home: URL) {
        self.home = home
        claude = home.appending(path: ".claude")
        codex = home.appending(path: ".codex")
        pi = home.appending(path: ".pi/agent")
        opencode = home.appending(path: ".local/share/opencode")
    }

    /// The live locations, honoring `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `PI_CODING_AGENT_DIR`.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentProjectScan {
        var scan = AgentProjectScan(home: FileManager.default.homeDirectoryForCurrentUser)
        func dir(_ key: String) -> URL? {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        }
        if let claude = dir("CLAUDE_CONFIG_DIR") { scan.claude = claude }
        if let codex = dir("CODEX_HOME") { scan.codex = codex }
        if let pi = dir("PI_CODING_AGENT_DIR") { scan.pi = pi }
        if let data = dir("XDG_DATA_HOME") { scan.opencode = data.appending(path: "opencode") }
        return scan
    }

    /// The projects, best first.
    public func run(now: Date = Date()) -> [AgentProject] {
        var byFolder: [String: AgentProject] = [:]
        for app in AgentApp.allCases {
            for (cwd, modified) in sessions(of: app) {
                let path = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
                var project = byFolder[path] ?? AgentProject(folder: URL(fileURLWithPath: path, isDirectory: true),
                                                             sessions: 0, lastActive: .distantPast, apps: [])
                project.sessions += 1
                project.lastActive = max(project.lastActive, modified)
                if !project.apps.contains(app) { project.apps.append(app) }
                byFolder[path] = project
            }
        }
        // A project may have no surviving agent transcript yet. Repositories
        // under the conventional Projects roots are safe, useful fallbacks
        // for the first chat and keep project picking from opening a panel.
        for folder in gitRepositories() {
            let path = folder.standardizedFileURL.path
            if byFolder[path] == nil {
                byFolder[path] = AgentProject(folder: folder, sessions: 0, lastActive: modified(folder), apps: [])
            }
        }
        return byFolder.values
            .filter(keeps)
            .map { var p = $0; p.apps.sort(); return p }
            .sorted {
                if ($0.sessions > 0) != ($1.sessions > 0) { return $0.sessions > 0 }
                return Self.score($0, now: now) == Self.score($1, now: now) ? $0.folder.path < $1.folder.path
                    : Self.score($0, now: now) > Self.score($1, now: now)
            }
    }

    /// Finds git repositories below the user's Projects-style roots without
    /// walking arbitrary home directories or privacy-protected locations.
    private func gitRepositories() -> [URL] {
        let roots = [home.appending(path: "Projects"), home.appending(path: "projects")]
        let manager = FileManager.default
        var found: [URL] = []
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == ".git" else { continue }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let repository = url.deletingLastPathComponent().standardizedFileURL
                if !found.contains(repository) { found.append(repository) }
                enumerator.skipDescendants()
                if found.count >= 200 { break }
            }
        }
        return found
    }

    /// Recency first, with session count as weight: a project used daily
    /// outranks one used heavily months ago.
    static func score(_ project: AgentProject, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(project.lastActive) / 86_400)
        return log2(1 + Double(project.sessions)) - days / 14
    }

    /// The privacy-protected folder `folder` sits in, if any.
    public func privacyFolder(of folder: URL) -> PrivacyFolder? {
        // The Mac's disk ignores case, so `~/desktop/x` is on the Desktop too.
        let path = folder.standardizedFileURL.path.lowercased()
        return PrivacyFolder.allCases.first { kind in
            let root = kind.root(home: home).lowercased()
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private func keeps(_ project: AgentProject) -> Bool { keeps(folder: project.folder) }

    /// False for the home folder, temporary folders, an agent's own folders
    /// and folders that are gone; privacy-protected folders are kept unlooked-at.
    func keeps(folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path != "/", path != homePath, path.hasPrefix("/") else { return false }
        let inHome = path.hasPrefix(homePath + "/")
        for temporary in ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
        where !inHome && (path == temporary || path.hasPrefix(temporary + "/")) {
            return false
        }
        for agentHome in [claude, codex, pi, opencode] where path.hasPrefix(agentHome.standardizedFileURL.path + "/") {
            return false
        }
        if privacyFolder(of: folder) != nil { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Each session of `app`: its recorded cwd and when it was last written.
    private func sessions(of app: AgentApp) -> [(String, Date)] {
        let files: [URL]
        switch app {
        case .claudeCode: files = Self.files(in: claude.appending(path: "projects"), depth: 1, ext: "jsonl")
        case .codex: files = Self.files(in: codex.appending(path: "sessions"), depth: 3, ext: "jsonl").filter { $0.lastPathComponent.hasPrefix("rollout-") }
        case .pi: files = Self.files(in: pi.appending(path: "sessions"), depth: 1, ext: "jsonl")
        case .opencode: files = Self.files(in: opencode.appending(path: "storage/session"), depth: 1, ext: "json")
        }
        let dated = files.map { ($0, Self.modified($0)) }.sorted { $0.1 > $1.1 }.prefix(filesPerApp)
        return dated.compactMap { file, modified in Self.recordedCwd(app, file).map { ($0, modified) } }
    }

    /// Files with extension `ext` exactly `depth` folders below `root`.
    static func files(in root: URL, depth: Int, ext: String) -> [URL] {
        let manager = FileManager.default
        var level = [root]
        for _ in 0..<depth {
            level = level.flatMap { dir in
                ((try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
        }
        return level.flatMap { dir in
            ((try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == ext }
        }
    }

    static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The cwd from the start of a session file (its first 64 KB).
    static func recordedCwd(_ app: AgentApp, _ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        if app == .opencode {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return nonEmpty(object?["directory"])
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                // A first record longer than the read (Codex puts its
                // instructions in `session_meta`) is cut off; its cwd may
                // still be in the part that was read.
                if let cwd = cwdField(in: line) { return cwd }
                continue
            }
            let cwd: Any? = switch app {
            case .codex: object["type"] as? String == "session_meta" ? (object["payload"] as? [String: Any])?["cwd"] : nil
            default: object["cwd"]
            }
            if let cwd = nonEmpty(cwd) { return cwd }
        }
        return nil
    }

    /// The first `"cwd":"..."` string in a record that does not parse.
    static func cwdField(in line: Data.SubSequence) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        guard let key = text.range(of: #""cwd":""#) ?? text.range(of: #""cwd": ""#) else { return nil }
        var literal = "\""
        var escaped = false
        for character in text[key.upperBound...] {
            literal.append(character)
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
        }
        guard literal.count > 2, literal.hasSuffix("\""),
              let value = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String else { return nil }
        return nonEmpty(value)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
