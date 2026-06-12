import CMUXAgentLaunch
import Foundation

/// Resolves a focused panel to the agent transcript file it should render.
///
/// Reuses the existing restorable-session index (`RestorableAgentSessionIndex`)
/// to get a panel's `(kind, sessionId, workingDirectory)`, then locates the
/// transcript with the same conventions the resume path uses: for Claude Code,
/// the `~/.claude/projects/<encode(cwd)>/<sessionId>.jsonl` file (with a
/// fallback scan across project dirs); for Codex, a newest-first walk of
/// `<sessionId>` under `~/.codex/sessions`. The resolved absolute path is
/// handed to the agent daemon (`agent.session.open` with `transcript_path`),
/// which parses and tails it.
struct AgentChatTranscriptResolver {
    /// The wire provider ids of the agent conversation protocol
    /// (webviews/src/agent-chat/protocol.ts).
    enum Provider: String {
        case claude
        case codex
    }

    /// The agent home directory (defaults to the real home).
    private let homeDirectory: String

    /// The filesystem used for lookups (injectable for tests).
    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - homeDirectory: The home directory holding `~/.claude` and `~/.codex`.
    ///   - fileManager: The filesystem to query.
    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    /// The provider plus the resolved transcript file for a panel.
    struct Resolution {
        /// The wire provider id for the chat protocol.
        let provider: Provider
        /// The agent session id.
        let sessionId: String
        /// The panel's working directory, when known.
        let workingDirectory: String?
        /// The located transcript file, or `nil` if none was found.
        let transcriptURL: URL?
    }

    /// Resolves a panel's transcript from the restorable-session index, with
    /// the workspace's in-memory restored-agent snapshot and the panel's
    /// persisted resume binding as fallbacks (in that order).
    ///
    /// The hook-session index is keyed by the `(workspaceId, panelId)` pair the
    /// agent's hooks last reported. A freshly RESTORED panel has new ids and
    /// its resumed agent has not fired a hook yet, so the index lookup misses;
    /// the restored snapshot (the same source the resume path launched from)
    /// covers that window. When neither exists (e.g. the in-memory snapshot
    /// was consumed or never captured), the panel's persisted resume binding
    /// (kind + session id + cwd + env, the same tuple cmux resumes from)
    /// still locates the transcript. The index entry wins when several
    /// sources exist because hooks track live session-id changes (e.g. a
    /// resume fork).
    ///
    /// - Parameters:
    ///   - index: The loaded restorable-session index.
    ///   - restoredSnapshot: The workspace's in-memory restored-agent snapshot
    ///     for the panel, when one exists.
    ///   - workspaceId: The panel's workspace id.
    ///   - panelId: The panel id.
    ///   - resumeBinding: The panel's persisted surface resume binding,
    ///     consulted when both the index and the restored snapshot miss.
    /// - Returns: The resolution, or `nil` when the panel has no known agent
    ///   session or the agent kind is not a transcript-backed kind P1 supports.
    func resolve(
        index: RestorableAgentSessionIndex,
        restoredSnapshot: SessionRestorableAgentSnapshot?,
        workspaceId: UUID,
        panelId: UUID,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil
    ) -> Resolution? {
        let indexSnapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "agentChat.resolve.sources indexHit=\(indexSnapshot != nil ? 1 : 0) " +
            "restoredHit=\(restoredSnapshot != nil ? 1 : 0) " +
            "bindingHit=\(resumeBinding != nil ? 1 : 0)"
        )
#endif
        let snapshotInputs = (indexSnapshot ?? restoredSnapshot).map { snapshot in
            ResolutionInputs(
                kind: snapshot.kind,
                sessionId: snapshot.sessionId,
                cwd: snapshot.workingDirectory,
                environment: snapshot.launchCommand?.environment
            )
        }
        guard let inputs = snapshotInputs ?? resumeBindingInputs(resumeBinding) else {
#if DEBUG
            cmuxDebugLog(
                "agentChat.resolve.miss reason=noIndexEntryOrRestoredSnapshotOrBinding " +
                "ws=\(workspaceId.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5))"
            )
#endif
            return nil
        }
        let sessionId = inputs.sessionId
        guard !sessionId.isEmpty else {
#if DEBUG
            cmuxDebugLog("agentChat.resolve.miss reason=emptySessionId kind=\(inputs.kind.rawValue)")
#endif
            return nil
        }
        let cwd = inputs.cwd
#if DEBUG
        cmuxDebugLog(
            "agentChat.resolve.snapshot kind=\(inputs.kind.rawValue) " +
            "session=\(sessionId.prefix(8)) hasCwd=\(cwd != nil ? 1 : 0)"
        )
#endif

        switch inputs.kind {
        case .claude:
            let configuredRoot = inputs.environment?["CLAUDE_CONFIG_DIR"]
            let transcriptURL = claudeTranscriptURL(
                sessionId: sessionId,
                cwd: cwd,
                configuredRoot: configuredRoot
            )
#if DEBUG
            cmuxDebugLog(
                "agentChat.resolve.claude session=\(sessionId.prefix(8)) " +
                "transcriptFound=\(transcriptURL != nil ? 1 : 0)"
            )
#endif
            return Resolution(
                provider: .claude,
                sessionId: sessionId,
                workingDirectory: cwd,
                transcriptURL: transcriptURL
            )
        case .codex:
            let codexHome = inputs.environment?["CODEX_HOME"]
            let transcriptURL = codexTranscriptURL(sessionId: sessionId, codexHome: codexHome)
#if DEBUG
            cmuxDebugLog(
                "agentChat.resolve.codex session=\(sessionId.prefix(8)) " +
                "transcriptFound=\(transcriptURL != nil ? 1 : 0)"
            )
#endif
            return Resolution(
                provider: .codex,
                sessionId: sessionId,
                workingDirectory: cwd,
                transcriptURL: transcriptURL
            )
        default:
            // Other agents are not transcript-backed in the P1 parsers.
#if DEBUG
            cmuxDebugLog("agentChat.resolve.miss reason=unsupportedKind kind=\(inputs.kind.rawValue)")
#endif
            return nil
        }
    }

    /// The transcript-lookup inputs for a panel, normalized from whichever
    /// source resolved them (index snapshot, restored snapshot, or persisted
    /// resume binding).
    private struct ResolutionInputs {
        let kind: RestorableAgentKind
        let sessionId: String
        let cwd: String?
        let environment: [String: String]?
    }

    /// Inputs reconstructed from a panel's persisted resume binding, used when
    /// both the live index and the restored snapshot miss (e.g. a terminal
    /// restored after an app relaunch whose in-memory snapshot is gone). The
    /// binding's `checkpointId` is the agent session id the resume path uses;
    /// `kind` is the persisted agent-kind string.
    private func resumeBindingInputs(_ binding: SurfaceResumeBindingSnapshot?) -> ResolutionInputs? {
        guard let binding,
              let sessionId = binding.checkpointId,
              isSafeSessionFilenameComponent(sessionId),
              let kind = restorableKind(fromBindingKind: binding.kind) else {
            return nil
        }
        return ResolutionInputs(
            kind: kind,
            sessionId: sessionId,
            cwd: binding.cwd,
            environment: binding.environment
        )
    }

    /// Whether a session id from a persisted resume binding is safe to use as a
    /// transcript filename component. The resume binding is a trust boundary
    /// (it can be created through the public resume path and does not validate
    /// the checkpoint id), and the session id is later appended to a project /
    /// sessions directory, so a value containing a path separator or `..` could
    /// escape into another reachable `.jsonl`. Mirrors the live index path's
    /// Claude safe-filename invariant.
    private func isSafeSessionFilenameComponent(_ sessionId: String) -> Bool {
        !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
            && sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
    }

    /// Maps a resume binding's kind string to a `RestorableAgentKind`, limited
    /// to the transcript-backed kinds the P1 parsers support.
    private func restorableKind(fromBindingKind kind: String?) -> RestorableAgentKind? {
        switch kind?.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    /// Locates a Claude transcript across the same config roots the resume path
    /// honors: a launch-time `CLAUDE_CONFIG_DIR` (highest priority), `~/.claude`,
    /// and any `~/.codex-accounts/claude/*` account root. Within each root it
    /// prefers the encoded-cwd project dir, then scans all project dirs for
    /// `<sessionId>.jsonl`.
    private func claudeTranscriptURL(sessionId: String, cwd: String?, configuredRoot: String?) -> URL? {
        let fileName = "\(sessionId).jsonl"
        for configRoot in claudeConfigRoots(configuredRoot: configuredRoot) {
            let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")

            if let cwd {
                // Single-source the encoding with the resume path.
                let dirName = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
                let path = (projectsRoot as NSString)
                    .appendingPathComponent(dirName)
                    .appending("/")
                    .appending(fileName)
                if regularFileExists(path) { return URL(fileURLWithPath: path) }
            }

            guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
                continue
            }
            for dir in projectDirs {
                let path = (projectsRoot as NSString)
                    .appendingPathComponent(dir)
                    .appending("/")
                    .appending(fileName)
                if regularFileExists(path) { return URL(fileURLWithPath: path) }
            }

            // Workflow/sub-agent case: the recorded session id is a *container*
            // directory and the real transcript is a newer sibling `.jsonl`
            // with a different id in the same project dir. Mirrors the live
            // index path's workflow-container resolution so restored workflow
            // panels resolve their transcript too.
            for dir in projectDirs {
                let projectDir = (projectsRoot as NSString).appendingPathComponent(dir)
                let container = (projectDir as NSString).appendingPathComponent(sessionId)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: container, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                if let sibling = newestSiblingTranscript(in: projectDir, excludingSessionId: sessionId) {
                    return sibling
                }
            }
        }
        return nil
    }

    /// The newest `<id>.jsonl` transcript in `projectDir` whose id is not
    /// `excludedSessionId`, by file modification time. Used for the Claude
    /// workflow-container fallback.
    private func newestSiblingTranscript(in projectDir: String, excludingSessionId excluded: String) -> URL? {
        guard let children = try? fileManager.contentsOfDirectory(atPath: projectDir) else { return nil }
        var best: (url: URL, modifiedAt: Date)?
        for child in children where child.hasSuffix(".jsonl") {
            let id = String(child.dropLast(".jsonl".count))
            guard id != excluded, !id.isEmpty else { continue }
            let path = (projectDir as NSString).appendingPathComponent(child)
            guard regularFileExists(path) else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            let when = modified ?? .distantPast
            if best == nil || when > best!.modifiedAt {
                best = (URL(fileURLWithPath: path), when)
            }
        }
        return best?.url
    }

    /// The ordered Claude config roots to search, mirroring the restore/resume
    /// path's `RestorableAgentSessionIndex.ClaudeTranscriptLookupCache.configRoots`
    /// exactly so a session the resume path can find is found here too.
    ///
    /// When a launch-time `CLAUDE_CONFIG_DIR` is set, that preferred-path root is
    /// the *only* root (the same single-root behavior the resume path uses).
    /// Otherwise the order is: each `~/.codex-accounts/claude/*` multi-account
    /// root (sorted), then `~/.claude`, then the legacy
    /// `~/.subrouter/codex/claude` preferred path.
    private func claudeConfigRoots(configuredRoot: String?) -> [String] {
        if let configuredRoot, !configuredRoot.isEmpty {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    configuredRoot,
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        var roots: [String] = []
        var seen: Set<String> = []
        func append(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                append((accountRoot as NSString).appendingPathComponent(accountDir))
            }
        }
        append((homeDirectory as NSString).appendingPathComponent(".claude"))
        append(
            ClaudeConfigDirectoryPath.preferredPath(
                (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        )
        return roots
    }

    /// Locates a Codex rollout under the `sessions` tree of the captured
    /// `CODEX_HOME` (when set), then the default `~/.codex`. The tree is
    /// partitioned `YYYY/MM/DD/rollout-<ISO>-<sessionId>.jsonl`; the walk is
    /// newest-day-first so the cost is bounded to the most recent days.
    private func codexTranscriptURL(sessionId: String, codexHome: String?) -> URL? {
        // The id is the exact suffix; matching the suffix (not a substring)
        // avoids binding to another rollout whose id merely contains this one.
        let suffix = "-\(sessionId).jsonl"

        func children(_ path: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >)
        }
        func match(inDay dayDir: String) -> URL? {
            guard let names = try? fileManager.contentsOfDirectory(atPath: dayDir) else { return nil }
            guard let name = names.filter({ $0.hasSuffix(suffix) }).sorted().last else { return nil }
            return URL(fileURLWithPath: (dayDir as NSString).appendingPathComponent(name))
        }

        for sessionsRoot in codexSessionsRoots(codexHome: codexHome) {
            for year in children(sessionsRoot) {
                let yearPath = (sessionsRoot as NSString).appendingPathComponent(year)
                for month in children(yearPath) {
                    let monthPath = (yearPath as NSString).appendingPathComponent(month)
                    for day in children(monthPath) {
                        if let url = match(inDay: (monthPath as NSString).appendingPathComponent(day)) {
                            return url
                        }
                    }
                }
            }
        }
        return nil
    }

    /// The ordered Codex `sessions` roots to search: the captured `CODEX_HOME`
    /// first (when set), then the default `~/.codex`.
    private func codexSessionsRoots(codexHome: String?) -> [String] {
        var roots: [String] = []
        var seen: Set<String> = []
        func append(_ home: String) {
            let expanded = (home as NSString).expandingTildeInPath
            let sessions = ((expanded as NSString).appendingPathComponent("sessions") as NSString)
                .standardizingPath
            guard !sessions.isEmpty, seen.insert(sessions).inserted else { return }
            roots.append(sessions)
        }
        if let codexHome, !codexHome.isEmpty { append(codexHome) }
        append((homeDirectory as NSString).appendingPathComponent(".codex"))
        return roots
    }

    /// Whether a regular (non-directory) file exists at the path.
    private func regularFileExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
}
