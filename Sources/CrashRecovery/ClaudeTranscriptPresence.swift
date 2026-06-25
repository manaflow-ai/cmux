import Foundation
#if canImport(CMUXAgentLaunch)
import CMUXAgentLaunch
#endif

/// On-disk presence of a Claude transcript, split into the two signals the
/// verification gate needs (U10): does the transcript for `sessionId` exist
/// **at this window's own cwd** (Claude namespaces each transcript under
/// `<config>/projects/<encode(launch cwd)>/<id>.jsonl`), and does it exist under
/// some *other* project dir? "At cwd" doubles as the cwd-match check; "elsewhere
/// only" is the anti-Example-3 mis-attribution.
///
/// This deliberately READS where the transcript lives; it does NOT fix where the
/// auto-resume binding points (that is PR #6741's `ClaudeResumeWorkingDirectory`).
/// The two compose: #6741 makes `claude --resume` cd into the right project dir,
/// and this check decides whether cmux should hand the agent a verified
/// breadcrumb vs. the honest recovery prompt. Self-contained so the PR
/// stands alone before #6741 lands; once #6741 is in, the resolver can defer to
/// its shared `ClaudeProjectDirEncoding`.
nonisolated struct ClaudeTranscriptPresence: Equatable, Sendable {
    /// A transcript for the session exists at the project dir derived from this
    /// window's cwd.
    var existsAtWindowCwd: Bool
    /// A transcript for the session exists under some other project dir.
    var existsElsewhere: Bool
    /// The resolved on-disk transcript path when found at the window's cwd.
    /// Internal evidence only; user-facing breadcrumbs do not expose it.
    var resolvedPathAtWindowCwd: String?
    /// Whether the resolver performed the historical-project fallback scan.
    /// Restore-time name verification leaves this false to avoid unbounded launch
    /// filesystem work; explicit recovery can recompute with the scan enabled.
    var searchedElsewhere: Bool = true

    static let absent = ClaudeTranscriptPresence(
        existsAtWindowCwd: false,
        existsElsewhere: false,
        resolvedPathAtWindowCwd: nil,
        searchedElsewhere: false
    )

    static func == (lhs: ClaudeTranscriptPresence, rhs: ClaudeTranscriptPresence) -> Bool {
        lhs.existsAtWindowCwd == rhs.existsAtWindowCwd
            && lhs.existsElsewhere == rhs.existsElsewhere
            && lhs.resolvedPathAtWindowCwd == rhs.resolvedPathAtWindowCwd
    }
}

/// Resolves `ClaudeTranscriptPresence` from the filesystem. Pure given its
/// injected `FileManager` + home dir, so it is unit-testable with a temp tree.
enum ClaudeTranscriptPresenceResolver {

    /// - Parameters:
    ///   - sessionId: the bare Claude session id (NOT a resume command string).
    ///   - cwd: the window's working directory (the launch cwd Claude filed under).
    ///   - configDirOverride: a `CLAUDE_CONFIG_DIR` value captured in the binding's
    ///     launch environment, if any.
    static func resolve(
        sessionId: String?,
        cwd: String?,
        configDirOverride: String? = nil,
        searchElsewhere: Bool = true,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> ClaudeTranscriptPresence {
        guard let sessionId = nonEmpty(sessionId),
              isSafeFilename(sessionId),
              let cwd = nonEmpty(cwd) else {
            return .absent
        }

        let roots = configRoots(
            configDirOverride: configDirOverride,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        guard !roots.isEmpty else { return .absent }

        let windowProjectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)

        var resolvedAtCwd: String?
        var existsElsewhere = false

        for root in roots {
            let projectsDir = (root as NSString).appendingPathComponent("projects")

            // At the window's own cwd.
            if resolvedAtCwd == nil {
                let projectRoot = (projectsDir as NSString).appendingPathComponent(windowProjectDir)
                if let path = transcriptPath(inProjectRoot: projectRoot, sessionId: sessionId, fileManager: fileManager) {
                    resolvedAtCwd = path
                }
            }

            // Under any *other* project dir. This scan is only needed when the
            // transcript was not found at this window's cwd; once at-cwd exists,
            // the binding is verified and "elsewhere too" does not change the
            // routing decision.
            if searchElsewhere,
               resolvedAtCwd == nil,
               !existsElsewhere,
               let children = try? fileManager.contentsOfDirectory(atPath: projectsDir) {
                for child in children where child != windowProjectDir {
                    let projectRoot = (projectsDir as NSString).appendingPathComponent(child)
                    if transcriptPath(inProjectRoot: projectRoot, sessionId: sessionId, fileManager: fileManager) != nil {
                        existsElsewhere = true
                        break
                    }
                }
            }
        }

        return ClaudeTranscriptPresence(
            existsAtWindowCwd: resolvedAtCwd != nil,
            existsElsewhere: existsElsewhere,
            resolvedPathAtWindowCwd: resolvedAtCwd,
            searchedElsewhere: searchElsewhere
        )
    }

    /// The Claude config roots a transcript may live under. Mirrors the set the
    /// restore index resolves: an explicit `CLAUDE_CONFIG_DIR` (normalized for the
    /// legacy `.subrouter` → `.codex-accounts` move), `~/.claude`, each
    /// `~/.codex-accounts/claude/<account>`, and `~/.subrouter/codex/claude`.
    /// Under-detection here is safe: a missed transcript falls to honest recovery,
    /// never a wrong resume.
    static func configRoots(
        configDirOverride: String?,
        fileManager: FileManager,
        homeDirectory: String
    ) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        func add(_ path: String?) {
            guard let path = nonEmpty(path) else { return }
            let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        if let override = nonEmpty(configDirOverride) {
            #if canImport(CMUXAgentLaunch)
            add(ClaudeConfigDirectoryPath.preferredPath(override, fileManager: fileManager, homeDirectory: homeDirectory))
            #else
            add(override)
            #endif
            return roots
        }

        let home = ((homeDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
        add((home as NSString).appendingPathComponent(".claude"))

        let accountsRoot = (home as NSString).appendingPathComponent(".codex-accounts/claude")
        if let accounts = try? fileManager.contentsOfDirectory(atPath: accountsRoot) {
            for account in accounts.sorted() {
                add((accountsRoot as NSString).appendingPathComponent(account))
            }
        }
        add((home as NSString).appendingPathComponent(".subrouter/codex/claude"))

        return roots
    }

    /// The transcript file for `sessionId` under a project dir, or nil. Covers the
    /// two layouts Claude uses: `<projectRoot>/<id>.jsonl` and the nested
    /// `<projectRoot>/<id>/messages/<id>.jsonl`.
    private static func transcriptPath(
        inProjectRoot projectRoot: String,
        sessionId: String,
        fileManager: FileManager
    ) -> String? {
        let flat = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: flat, fileManager: fileManager) { return flat }
        let nested = (((projectRoot as NSString)
            .appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: nested, fileManager: fileManager) { return nested }
        return nil
    }

    private static func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        return (size ?? 1) > 0
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Guards against a session id that would escape the project dir or name a
    /// path separator (the transcript filename is `<id>.jsonl`).
    private static func isSafeFilename(_ id: String) -> Bool {
        !id.contains("/") && !id.contains("..") && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resolves Codex rollout transcript presence by exact session id and cwd.
///
/// Codex rollouts live under `CODEX_HOME` (or `~/.codex`) as
/// `sessions/YYYY/MM/DD/rollout-...<session-id>....jsonl`, with older rollouts
/// also valid under `archived_sessions`. The first line is `session_meta`, which
/// carries both the canonical session id and the cwd. This resolver only verifies
/// a binding when both values match the restored window.
enum CodexTranscriptPresenceResolver {
    private static let headByteCap = 64 * 1024
    private static let recentDayLimit = 370

    static func resolve(
        sessionId: String?,
        cwd: String?,
        codexHomeOverride: String? = nil,
        searchElsewhere: Bool = true,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> ClaudeTranscriptPresence {
        guard let sessionId = nonEmpty(sessionId),
              isSafeFilename(sessionId),
              let cwd = nonEmpty(cwd) else {
            return .absent
        }
        guard searchElsewhere else {
            return .absent
        }

        var resolvedAtCwd: String?
        var existsElsewhere = false
        let needle = sessionId.lowercased()

        for root in codexRoots(
            codexHomeOverride: codexHomeOverride,
            homeDirectory: homeDirectory
        ) {
            for sessionsDirectoryName in ["sessions", "archived_sessions"] {
                let sessionsRoot = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(sessionsDirectoryName, isDirectory: true)
                for directory in recentSessionDirectories(sessionsRoot: sessionsRoot) {
                    guard !Task.isCancelled else { return .absent }
                    guard resolvedAtCwd == nil else { break }
                    guard let entries = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for url in entries {
                        guard !Task.isCancelled else { return .absent }
                        guard url.pathExtension == "jsonl",
                              url.lastPathComponent.lowercased().contains(needle),
                              let meta = sessionMeta(in: url),
                              meta.sessionId == sessionId else {
                            continue
                        }
                        if cwdMatches(meta.cwd, cwd) {
                            resolvedAtCwd = url.path
                            break
                        } else if nonEmpty(meta.cwd) != nil {
                            existsElsewhere = true
                        }
                    }
                }
            }
        }

        return ClaudeTranscriptPresence(
            existsAtWindowCwd: resolvedAtCwd != nil,
            existsElsewhere: resolvedAtCwd == nil && existsElsewhere,
            resolvedPathAtWindowCwd: resolvedAtCwd,
            searchedElsewhere: searchElsewhere
        )
    }

    private static func codexRoots(codexHomeOverride: String?, homeDirectory: String) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        func add(_ path: String?) {
            guard let path = nonEmpty(path) else { return }
            let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        if let codexHomeOverride = nonEmpty(codexHomeOverride) {
            add(codexHomeOverride)
            return roots
        }
        let home = ((homeDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
        add((home as NSString).appendingPathComponent(".codex"))
        return roots
    }

    private static func recentSessionDirectories(sessionsRoot: URL, now: Date = Date()) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return (0..<recentDayLimit).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { return nil }
            return sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private static func sessionMeta(in url: URL) -> (sessionId: String, cwd: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: headByteCap)
        guard !data.isEmpty else {
            return nil
        }
        let head = String(decoding: data, as: UTF8.self)
        let firstLine = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let firstLine,
              let lineData = String(firstLine).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let sessionId = nonEmpty(payload["id"] as? String) else {
            return nil
        }
        return (sessionId, payload["cwd"] as? String)
    }

    private static func cwdMatches(_ transcriptCwd: String?, _ windowCwd: String) -> Bool {
        guard let transcriptCwd = nonEmpty(transcriptCwd) else { return false }
        let transcriptCandidates = Set(cwdCandidates(transcriptCwd))
        let windowCandidates = Set(cwdCandidates(windowCwd))
        return !transcriptCandidates.isDisjoint(with: windowCandidates)
    }

    private static func cwdCandidates(_ value: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String) {
            let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return }
            result.append(standardized)
        }

        let privateRoot = "/private"
        let resolved = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
        for base in [value, resolved] {
            add(base)
            if base.hasPrefix(privateRoot + "/") {
                add(String(base.dropFirst(privateRoot.count)))
            } else if base.hasPrefix("/") {
                add(privateRoot + base)
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isSafeFilename(_ id: String) -> Bool {
        !id.contains("/") && !id.contains("..") && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
