import CMUXAgentLaunch
import CmuxAgentConversation
import Foundation

/// Resolves a focused panel to the agent transcript file it should render.
///
/// Reuses the existing restorable-session index (`RestorableAgentSessionIndex`)
/// to get a panel's `(kind, sessionId, workingDirectory)`, then locates the
/// transcript with the same conventions the resume path uses: for Claude Code,
/// the `~/.claude/projects/<encode(cwd)>/<sessionId>.jsonl` file (with a
/// fallback scan across project dirs); for Codex, a glob of `<sessionId>` under
/// `~/.codex/sessions`.
struct AgentChatTranscriptResolver {
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

    /// The agent kind plus the resolved transcript URL for a panel.
    struct Resolution {
        /// The normalized agent kind for the chat model.
        let agentKind: AgentKind
        /// The agent session id.
        let sessionId: String
        /// The located transcript file, or `nil` if none was found.
        let transcriptURL: URL?
    }

    /// Resolves a panel's transcript from the restorable-session index.
    ///
    /// - Parameters:
    ///   - index: The loaded restorable-session index.
    ///   - workspaceId: The panel's workspace id.
    ///   - panelId: The panel id.
    ///   - resumeBinding: The panel's surface resume binding, consulted when
    ///     the live index has no entry for the panel.
    /// - Returns: The resolution, or `nil` when the panel has no known agent
    ///   session or the agent kind is not a transcript-backed kind P1 supports.
    func resolve(
        index: RestorableAgentSessionIndex,
        workspaceId: UUID,
        panelId: UUID,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil
    ) -> Resolution? {
        // Prefer the live index; fall back to the panel's resume binding when
        // the index has no entry. A session-restored terminal does not
        // repopulate the live hook index until the agent re-announces, but its
        // resume binding (kind + session id + cwd + env) was persisted at
        // restore, so the chat view can still find the transcript. Only give up
        // (the "No agent conversation" empty state) when neither source
        // yields a transcript-backed agent session.
        guard let inputs = indexInputs(index: index, workspaceId: workspaceId, panelId: panelId)
            ?? resumeBindingInputs(resumeBinding) else {
            return nil
        }
        guard !inputs.sessionId.isEmpty else { return nil }

        switch inputs.kind {
        case .claude:
            return Resolution(
                agentKind: .claudeCode,
                sessionId: inputs.sessionId,
                transcriptURL: claudeTranscriptURL(
                    sessionId: inputs.sessionId,
                    cwd: inputs.cwd,
                    configuredRoot: inputs.environment?["CLAUDE_CONFIG_DIR"]
                )
            )
        case .codex:
            return Resolution(
                agentKind: .codex,
                sessionId: inputs.sessionId,
                transcriptURL: codexTranscriptURL(
                    sessionId: inputs.sessionId,
                    codexHome: inputs.environment?["CODEX_HOME"]
                )
            )
        default:
            // Other agents are not transcript-backed in the P1 parsers.
            return nil
        }
    }

    /// The transcript-lookup inputs for a panel, from one of the two sources.
    private struct ResolutionInputs {
        let kind: RestorableAgentKind
        let sessionId: String
        let cwd: String?
        let environment: [String: String]?
    }

    /// Inputs from the live restorable-session index, or `nil` when the index
    /// has no entry for the panel.
    private func indexInputs(
        index: RestorableAgentSessionIndex,
        workspaceId: UUID,
        panelId: UUID
    ) -> ResolutionInputs? {
        guard let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        return ResolutionInputs(
            kind: snapshot.kind,
            sessionId: snapshot.sessionId,
            cwd: snapshot.workingDirectory,
            environment: snapshot.launchCommand?.environment
        )
    }

    /// Inputs reconstructed from a panel's persisted resume binding, used when
    /// the live index misses (e.g. a terminal restored after an app relaunch).
    /// The binding's `checkpointId` is the agent session id the resume path
    /// uses; `kind` is the persisted agent-kind string.
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
            // index path's `resolvedClaudeWorkflowRecord` so restored workflow
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
    /// `CODEX_HOME` (when set), then the default `~/.codex`. Codex stores
    /// rollouts under `$CODEX_HOME/sessions`, matching the resume path's
    /// preserved env var.
    ///
    /// The tree is partitioned `YYYY/MM/DD/rollout-<ISO>-<sessionId>.jsonl`.
    /// Rather than recursively enumerating the whole history on every menu
    /// click, this walks the date directories newest-first and returns the
    /// first exact-suffix match, so the cost is bounded to the most recent days.
    private func codexTranscriptURL(sessionId: String, codexHome: String?) -> URL? {
        // The id is the exact suffix; matching the suffix (not a substring)
        // avoids binding to another rollout whose id merely contains this one.
        let suffix = "-\(sessionId).jsonl"

        // Check each `YYYY/MM/DD` directory newest-first and return as soon as a
        // match is found, so a session in the newest day never walks the whole
        // history. Directory names are zero-padded, so lexicographic-descending
        // order is chronological-descending.
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
