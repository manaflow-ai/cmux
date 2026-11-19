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
/// folder in a privacy-protected location (`PrivacyFolder`), by its spelling
/// or through a symlink, is kept without being looked at, since looking
/// would raise a macOS privacy prompt (LAUNCH-NO-TCC-PROMPTS). Reading the
/// agents' own folders raises none. Every probe outside the agents' folders
/// goes through `fileSystem`, so a test can prove which paths a scan touches.
public nonisolated struct AgentProjectScan: Sendable {
    public var home: URL
    public var claude: URL
    public var codex: URL
    public var pi: URL
    public var opencode: URL
    /// cmux's private agent-home folders (`AgentHome.standard`): a folderless workspace's chats
    /// run in `<workspace-id>` here, which is never a project to pick.
    public var cmuxAgentHome: URL
    /// The newest session files read per app; older ones add nothing a user would pick.
    public var filesPerApp = 2000
    /// The probes of project folders (existence, listing, symlinks).
    public var fileSystem = ScanFileSystem.live

    public init(home: URL) {
        self.home = home
        claude = home.appending(path: ".claude")
        codex = home.appending(path: ".codex")
        pi = home.appending(path: ".pi/agent")
        opencode = home.appending(path: ".local/share/opencode")
        cmuxAgentHome = home.appending(path: "Library/Application Support/cmux/agent-home")
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
                byFolder[path] = AgentProject(folder: folder, sessions: 0, lastActive: fileSystem.modified(path), apps: [])
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

    /// Finds git repositories below the user's Projects-style roots, at
    /// most `maxRepositoryDepth` folders down, without following a symlink
    /// or entering a privacy-protected location.
    private func gitRepositories() -> [URL] {
        let roots = [home.appending(path: "Projects"), home.appending(path: "projects")]
        var found: [URL] = []
        var seen = Set<String>()
        var queue: [(URL, Int)] = roots.map { ($0.standardizedFileURL, 0) }
        while !queue.isEmpty, found.count < 200 {
            let (directory, depth) = queue.removeFirst()
            // `~/Projects` and `~/projects` are one folder on a disk that ignores case.
            guard seen.insert(directory.path.lowercased()).inserted, isLookable(directory),
                  fileSystem.isDirectory(directory.path) else { continue }
            if fileSystem.exists(directory.appending(path: ".git").path) {
                found.append(directory)
                continue
            }
            guard depth < Self.maxRepositoryDepth else { continue }
            for entry in fileSystem.subdirectories(directory) {
                queue.append((directory.appending(path: entry, directoryHint: .isDirectory), depth + 1))
            }
        }
        return found
    }

    /// How deep below a Projects root a repository is looked for.
    static let maxRepositoryDepth = 3

    /// Recency first, with session count as weight: a project used daily
    /// outranks one used heavily months ago.
    static func score(_ project: AgentProject, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(project.lastActive) / 86_400)
        return log2(1 + Double(project.sessions)) - days / 14
    }

    /// The privacy-protected folder `folder` sits in by its spelling, if any.
    public func privacyFolder(of folder: URL) -> PrivacyFolder? {
        PrivacyFolder.of(path: folder.standardizedFileURL.path, home: home)
    }

    /// The privacy-protected folder `folder` reaches, by its spelling or
    /// through a symlink on its way. Resolving reads only link entries
    /// (`lstat`, `readlink`), which raise no prompt.
    public func protectedFolder(of folder: URL) -> PrivacyFolder? {
        if let kind = privacyFolder(of: folder) { return kind }
        let resolved = fileSystem.resolve(folder.standardizedFileURL.path)
        return PrivacyFolder.of(path: resolved, home: home)
    }

    /// True when a scan may look at `folder`: it is not, and does not lead
    /// into, a privacy-protected location.
    func isLookable(_ folder: URL) -> Bool { protectedFolder(of: folder) == nil }

    private func keeps(_ project: AgentProject) -> Bool { keeps(folder: project.folder) }

    /// False for the home folder, temporary folders, an agent's own folders
    /// (cmux's agent-home ones too) and folders that are gone; privacy-protected folders are kept unlooked-at.
    func keeps(folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path != "/", path != homePath, path.hasPrefix("/") else { return false }
        let inHome = path.hasPrefix(homePath + "/")
        for temporary in ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
        where !inHome && (path == temporary || path.hasPrefix(temporary + "/")) {
            return false
        }
        for agentHome in [claude, codex, pi, opencode, cmuxAgentHome] where path.hasPrefix(agentHome.standardizedFileURL.path + "/") {
            return false
        }
        if protectedFolder(of: folder) != nil { return true }
        return fileSystem.isDirectory(path)
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

/// The bounded project list used by the new-tab picker and onboarding.
///
/// Agent session files are the strongest signal, while a small scan of common
/// development roots keeps a fresh install useful before the first session.
/// The folders the user is most active in rank first: each repository's
/// newest git activity (its `HEAD` log, index and last fetch) and the
/// shell's visits (`FolderActivity`: zoxide, z, `cd` history), each visit
/// counted toward the repository it is in
/// (https://github.com/manaflow-ai/cmux/issues/46904).
/// Callers can pass cwd hints from classic/session history; those paths are
/// checked without walking their contents. The scan never descends into a
/// privacy-protected folder, and protected paths supplied as hints are kept
/// without an existence probe so choosing a project cannot cause a privacy
/// prompt.
public struct RecentProjectScan: Sendable {
    public let projects: AgentProjectScan
    public let roots: [URL]
    public let maxProjects: Int
    public let maxDepth: Int
    public let maxEntriesPerDirectory: Int
    /// The shell's visits; empty unless the caller read them (`live` does).
    public var activity = FolderActivity()

    public nonisolated init(projects: AgentProjectScan, roots: [URL]? = nil, maxProjects: Int = 50,
                maxDepth: Int = 2, maxEntriesPerDirectory: Int = 80, activity: FolderActivity = FolderActivity()) {
        self.projects = projects
        self.activity = activity
        self.roots = roots ?? Self.defaultRoots(home: projects.home)
        self.maxProjects = max(1, maxProjects)
        self.maxDepth = max(0, maxDepth)
        self.maxEntriesPerDirectory = max(1, maxEntriesPerDirectory)
    }

    public nonisolated init(home: URL, roots: [URL]? = nil, maxProjects: Int = 50,
                maxDepth: Int = 2, maxEntriesPerDirectory: Int = 80) {
        self.init(projects: AgentProjectScan(home: home), roots: roots, maxProjects: maxProjects,
                  maxDepth: maxDepth, maxEntriesPerDirectory: maxEntriesPerDirectory)
    }

    /// A scan rooted at the current user's home and agent configuration.
    public nonisolated static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> RecentProjectScan {
        let projects = AgentProjectScan.live(environment: environment)
        return RecentProjectScan(projects: projects, activity: FolderActivity.read(home: projects.home, environment: environment))
    }

    /// Returns recent projects, merging agent sessions, explicit cwd hints and
    /// bounded git repositories under the common development roots.
    public nonisolated func run(hints: [String] = [], now: Date = Date()) -> [AgentProject] {
        var byPath = Dictionary(uniqueKeysWithValues: projects.run(now: now).map { ($0.id, $0) })

        for hint in hints {
            guard let folder = normalizedFolder(hint), projects.keeps(folder: folder) else { continue }
            let id = folder.path
            if byPath[id] == nil {
                byPath[id] = AgentProject(folder: folder, sessions: 0, lastActive: now, apps: [])
            }
        }

        // The shell's visits, each credited to the repository it is in (a folder in none is not a project).
        var visits: [String: Double] = [:]
        for (folder, visit) in visitedRepositories() where projects.keeps(folder: folder) {
            let id = folder.path
            visits[id, default: 0] += visit.weight
            var project = byPath[id] ?? AgentProject(folder: folder, sessions: 0, lastActive: .distantPast, apps: [])
            project.lastActive = max(project.lastActive, min(visit.last, now))
            byPath[id] = project
        }

        for folder in gitRepositories() where projects.keeps(folder: folder) {
            let id = folder.path
            if byPath[id] == nil {
                let git = gitActivity(folder)
                byPath[id] = AgentProject(folder: folder, sessions: 0,
                                          lastActive: git == .distantPast ? projects.fileSystem.modified(folder.path) : min(git, now), apps: [])
            }
        }

        // Every candidate's git activity: the repository's own clock, not its folder's (which moves
        // only when a top-level entry comes or goes). A protected folder is never looked at.
        for (id, project) in byPath where projects.isLookable(project.folder) {
            let git = gitActivity(project.folder)
            if git > project.lastActive { byPath[id]?.lastActive = min(git, now) }
        }

        return byPath.values.sorted {
            let lhs = Self.score($0, visits: visits[$0.id] ?? 0, now: now)
            let rhs = Self.score($1, visits: visits[$1.id] ?? 0, now: now)
            return lhs == rhs ? $0.folder.path < $1.folder.path : lhs > rhs
        }.prefix(maxProjects).map { $0 }
    }

    /// Recency first, with agent sessions and shell visits as weight: a
    /// repository worked in today outranks one visited often months ago.
    nonisolated static func score(_ project: AgentProject, visits: Double, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(project.lastActive) / 86_400)
        return log2(1 + Double(project.sessions) + visits) - days / 14
    }

    /// The most visited folders read for a scan; the rest add nothing a user would pick.
    nonisolated static let maxVisitedFolders = 400
    /// How many folders up from a visited one a repository is looked for.
    nonisolated static let maxRepositoryClimb = 6

    /// The repositories the shell visited, with their summed visits. A visited
    /// folder in a protected location, by its spelling or through a symlink,
    /// is dropped before anything looks at it; the climb stops at the home
    /// folder and at `/`, and never looks at a protected folder on the way.
    nonisolated func visitedRepositories() -> [(URL, FolderActivity.Visits)] {
        let fileSystem = projects.fileSystem
        let home = projects.home.standardizedFileURL.path
        var repositoryOf: [String: String?] = [:]
        func repository(containing path: String) -> String? {
            var current = path
            var climbed: [String] = []
            defer { for folder in climbed where repositoryOf[folder] == nil { repositoryOf[folder] = .some(nil) } }
            for _ in 0...Self.maxRepositoryClimb {
                if let known = repositoryOf[current] {
                    for folder in climbed { repositoryOf[folder] = known }
                    return known
                }
                guard current != "/", current != home,
                      projects.isLookable(URL(fileURLWithPath: current, isDirectory: true)) else { return nil }
                climbed.append(current)
                if fileSystem.exists(current + "/.git") {
                    for folder in climbed { repositoryOf[folder] = current }
                    return current
                }
                current = (current as NSString).deletingLastPathComponent
            }
            return nil
        }
        var byRepository: [String: FolderActivity.Visits] = [:]
        let ranked = activity.visits.sorted { $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight }
        for (path, visit) in ranked.prefix(Self.maxVisitedFolders) {
            guard projects.privacyFolder(of: URL(fileURLWithPath: path, isDirectory: true)) == nil,
                  let root = repository(containing: path) else { continue }
            var entry = byRepository[root] ?? FolderActivity.Visits(weight: 0, last: .distantPast)
            entry.weight = min(FolderActivity.maxWeight, entry.weight + visit.weight)
            entry.last = max(entry.last, visit.last)
            byRepository[root] = entry
        }
        return byRepository.map { (URL(fileURLWithPath: $0.key, isDirectory: true), $0.value) }
    }

    /// A repository's newest git activity: its `HEAD` log (commits, checkouts,
    /// pulls), index (staging) and last fetch; a linked worktree's are in the
    /// folder its `.git` file names. `distantPast` for a folder that is not one.
    nonisolated func gitActivity(_ folder: URL) -> Date {
        let fileSystem = projects.fileSystem
        let dotGit = folder.standardizedFileURL.path + "/.git"
        var gitDirs: [String] = []
        if fileSystem.isDirectory(dotGit) {
            gitDirs = [dotGit]
        } else if fileSystem.exists(dotGit) {
            gitDirs = [dotGit]
            if let data = fileSystem.readPrefix(dotGit, 4096),
               let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first,
               line.hasPrefix("gitdir: ") {
                let target = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                let absolute = target.hasPrefix("/") ? target : folder.standardizedFileURL.path + "/" + target
                let linked = URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL
                if projects.isLookable(linked) { gitDirs = [linked.path] }
            }
        } else {
            return .distantPast
        }
        var newest = Date.distantPast
        for gitDir in gitDirs {
            for file in ["logs/HEAD", "index", "FETCH_HEAD", "HEAD"] {
                newest = max(newest, fileSystem.modified(gitDir + "/" + file))
            }
        }
        if newest == .distantPast { newest = fileSystem.modified(dotGit) }
        return newest
    }

    /// Path candidates matching an explicit prefix or substring. The full
    /// path is returned so the caller can use it directly as a cwd.
    public nonisolated func complete(query: String, hints: [String] = [], limit: Int = 20) -> [String] {
        guard limit > 0 else { return [] }
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = normalizedQuery(raw)
        let foldedRaw = raw.lowercased()
        let foldedExpanded = expanded.lowercased()
        return run(hints: hints).compactMap { project in
            let path = project.folder.path
            let folded = path.lowercased()
            guard raw.isEmpty || folded.hasPrefix(foldedExpanded) || folded.contains(foldedRaw) else { return nil }
            return path
        }.prefix(limit).map { $0 }
    }

    public nonisolated func complete(_ query: String, hints: [String] = [], limit: Int = 20) -> [String] {
        complete(query: query, hints: hints, limit: limit)
    }

    private nonisolated static func defaultRoots(home: URL) -> [URL] {
        ["Projects", "Developer", "code", "src", "workspaces", "dev", "repos", "git", "github", "work"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
    }

    private nonisolated func normalizedFolder(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private nonisolated func normalizedQuery(_ query: String) -> String {
        let expanded = (query as NSString).expandingTildeInPath
        return expanded.isEmpty ? "" : (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path : expanded)
    }

    /// Finds repositories at root, one child, or two children deep. Directory
    /// entries are capped to keep the new-tab request bounded on large homes.
    private nonisolated func gitRepositories() -> [URL] {
        var found: [URL] = []
        let fileSystem = projects.fileSystem
        // Never inspect a root inside a protected location, by its spelling
        // or through a symlink. Hints may name such a folder, but repository
        // discovery does not need to walk it and must not raise a privacy prompt.
        var queue = roots.prefix(maxEntriesPerDirectory)
            .map { $0.standardizedFileURL }
            .map { ($0, 0) }
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard projects.isLookable(directory), fileSystem.isDirectory(directory.path) else { continue }
            if fileSystem.exists(directory.appending(path: ".git").path) {
                found.append(directory)
                continue
            }
            guard depth < maxDepth else { continue }
            for entry in fileSystem.subdirectories(directory).prefix(maxEntriesPerDirectory) {
                // Keep the caller's root spelling (not /var to /private/var)
                // so these repositories merge with session and history cwd hints.
                queue.append((directory.appending(path: entry, directoryHint: .isDirectory), depth + 1))
            }
        }
        return found
    }
}
