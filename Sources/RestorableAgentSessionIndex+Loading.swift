import Foundation
import CMUXAgentLaunch


// MARK: - Loading
extension RestorableAgentSessionIndex {
    private struct SessionKey: Hashable {
        let kind: RestorableAgentKind
        let sessionId: String
    }

    // WARNING: Expensive. This reads every agent kind's hook-store file from disk,
    // resolves transcripts, and runs sysctl(KERN_PROCARGS2) per recorded session for
    // live-PID filtering (measured 350ms-1.8s on machines with large agent history).
    // NEVER call it synchronously on the main actor or in interactive paths (workspace/
    // panel/window close, SwiftUI body, didSet, menu evaluation, socket handlers). Read
    // the off-main, cached `SharedLiveAgentIndex.shared` instead. The only sanctioned
    // synchronous callers are cold-cache fallbacks guarded by a nil cache check.
    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }.value
    }

    private static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
    }

    static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval, processIDs: Set<Int>)],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: Entry] = [:]
        let claudeTranscriptLookup = ClaudeTranscriptLookupCache(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }
        var hookCandidatesBySession: [SessionKey: Entry] = [:]
        var hookCandidatesByPanel: [PanelKey: Entry] = [:]

        for (kind, registration) in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let effectiveRecord = kind == .claude
                    ? resolvedClaudeWorkflowRecord(
                        record,
                        fileManager: fileManager,
                        lookup: claudeTranscriptLookup
                    )
                    : record
                let normalizedSessionId = effectiveRecord.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: effectiveRecord.workspaceId),
                      let panelId = UUID(uuidString: effectiveRecord.surfaceId),
                      hookRecordIsRestorable(
                          effectiveRecord,
                          kind: kind,
                          fileManager: fileManager,
                          claudeTranscriptLookup: claudeTranscriptLookup
                      ) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: restorableWorkingDirectory(
                        for: effectiveRecord,
                        kind: kind,
                        registration: registration,
                        fileManager: fileManager,
                        lookup: claudeTranscriptLookup
                    ),
                    launchCommand: effectiveRecord.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                let sessionKey = SessionKey(kind: kind, sessionId: normalizedSessionId)
                let liveProcessID = liveScopedProcessID(
                    for: effectiveRecord,
                    kind: kind,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    processArgumentsProvider: processArgumentsProvider
                )
                let entry = Entry(
                    snapshot: snapshot,
                    lifecycle: effectiveRecord.agentLifecycle,
                    updatedAt: effectiveRecord.updatedAt,
                    processIDs: liveProcessID.map { [$0] } ?? []
                )
                if hookCandidatesByPanel[key]?.updatedAt ?? -Double.infinity <= effectiveRecord.updatedAt {
                    hookCandidatesByPanel[key] = entry
                }
                if hookCandidatesBySession[sessionKey]?.updatedAt ?? -Double.infinity <= effectiveRecord.updatedAt {
                    hookCandidatesBySession[sessionKey] = entry
                }
                guard effectiveRecord.pid == nil || liveProcessID != nil else {
                    continue
                }
                if let existing = resolved[key], existing.updatedAt > effectiveRecord.updatedAt {
                    continue
                }
                resolved[key] = entry
            }
        }

        for (key, detected) in detectedSnapshots {
            if let existing = Self.matchingHookEntry(
                for: detected.snapshot,
                resolved: resolved[key],
                panelCandidate: hookCandidatesByPanel[key],
                sessionCandidate: hookCandidatesBySession[
                    SessionKey(kind: detected.snapshot.kind, sessionId: detected.snapshot.sessionId)
                ]
            ) {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: existing.lifecycle,
                    updatedAt: existing.updatedAt,
                    processIDs: detected.processIDs
                )
            } else {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: nil,
                    updatedAt: 0,
                    processIDs: detected.processIDs
                )
            }
        }

        return RestorableAgentSessionIndex(entriesByPanel: resolved)
    }

    private static func matchingHookEntry(
        for snapshot: SessionRestorableAgentSnapshot,
        resolved: Entry?,
        panelCandidate: Entry?,
        sessionCandidate: Entry?
    ) -> Entry? {
        [resolved, panelCandidate, sessionCandidate].compactMap { $0 }
            .filter {
                $0.snapshot.kind == snapshot.kind &&
                    $0.snapshot.sessionId == snapshot.sessionId
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    private static func hookRecordIsRestorable(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        fileManager: FileManager,
        claudeTranscriptLookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard kind == .claude else {
            return record.isRestorable != false
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return true
        }
        return claudeTranscriptExists(for: record, fileManager: fileManager, lookup: claudeTranscriptLookup)
    }

    private static func resolvedClaudeWorkflowRecord(
        _ record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> RestorableAgentHookSessionRecord {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return record
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return record
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return record }
        let candidateProjectDirs = claudeWorkflowProjectDirs(
            for: record,
            sessionId: sessionId,
            roots: roots,
            fileManager: fileManager,
            lookup: lookup
        )
        guard let resolved = newestClaudeSiblingTranscript(
            in: candidateProjectDirs,
            excludingSessionId: sessionId,
            fileManager: fileManager
        ) else {
            return record
        }

        var resolvedRecord = record
        resolvedRecord.sessionId = resolved.sessionId
        resolvedRecord.transcriptPath = resolved.path
        return resolvedRecord
    }

    private static func claudeWorkflowProjectDirs(
        for record: RestorableAgentHookSessionRecord,
        sessionId: String,
        roots: [String],
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> [String] {
        var projectDirs: [String] = []
        var seen: Set<String> = []

        func appendIfWorkflowContainer(projectRoot: String) {
            let workflowContainer = (projectRoot as NSString).appendingPathComponent(sessionId)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workflowContainer, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let standardized = (projectRoot as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            projectDirs.append(standardized)
        }

        let cwdCandidates = [
            normalizedWorkingDirectory(record.launchCommand?.workingDirectory),
            normalizedWorkingDirectory(record.cwd),
        ].compactMap { $0 }
        for root in roots {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for cwd in cwdCandidates {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(encodeClaudeProjectDir(cwd))
                )
            }
            for projectDir in lookup.projectDirs(configRoot: root) {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(projectDir)
                )
            }
        }
        return projectDirs
    }

    private static func newestClaudeSiblingTranscript(
        in projectDirs: [String],
        excludingSessionId excludedSessionId: String,
        fileManager: FileManager
    ) -> (sessionId: String, path: String)? {
        var best: (sessionId: String, path: String, modifiedAt: TimeInterval)?
        for projectDir in projectDirs {
            guard let children = try? fileManager.contentsOfDirectory(atPath: projectDir) else {
                continue
            }
            for child in children where child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard sessionId != excludedSessionId,
                      claudeSessionIdIsSafeFilename(sessionId) else {
                    continue
                }
                let path = (projectDir as NSString).appendingPathComponent(child)
                guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager) else {
                    continue
                }
                let modifiedAt = ((try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                    .timeIntervalSince1970 ?? 0
                if best == nil || modifiedAt > best!.modifiedAt {
                    best = (sessionId, path, modifiedAt)
                }
            }
        }
        guard let best else { return nil }
        return (best.sessionId, best.path)
    }

    private static func claudeTranscriptExists(
        for record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return false }

        let cwd = normalizedWorkingDirectory(record.cwd)
            ?? normalizedWorkingDirectory(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               claudeTranscriptFileExists(
                   configRoot: root,
                   projectDirName: encodeClaudeProjectDir(cwd),
                   sessionId: sessionId,
                   fileManager: fileManager
               ) {
                return true
            }
            if claudeTranscriptFileExistsInAnyProject(
                configRoot: root,
                sessionId: sessionId,
                fileManager: fileManager,
                lookup: lookup
            ) {
                return true
            }
        }
        return false
    }

    /// The directory cmux must `cd` into to resume or fork this session.
    ///
    /// Many agents store their session under a directory derived from the cwd the session was
    /// *launched* in (Claude `projects/<encode(cwd)>/`, plus the Grok/Pi/Gemini/Cursor/Qoder
    /// cwd-keyed buckets), and `--resume` / `--fork` only locate it from that same directory. The
    /// hook-reported `cwd` drifts when the agent `cd`s elsewhere mid-session (e.g. starting in a
    /// repo root, then moving into a worktree), so trusting it makes resume fail with "No
    /// conversation found". For directory-namespaced kinds, prefer the stable launch cwd (it matches
    /// the namespace and never drifts); for Claude, first verify which candidate actually holds the
    /// transcript. For kinds that key sessions by id and record the cwd inside the session file
    /// (Codex, OpenCode, Amp, …), keep the recorded cwd so the resumed agent reopens where it was.
    private static func restorableWorkingDirectory(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        registration: CmuxVaultAgentRegistration?,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> String? {
        let recordedCwd = normalizedWorkingDirectory(record.cwd)
        let launchCwd = normalizedWorkingDirectory(record.launchCommand?.workingDirectory)

        // Custom Vault agents resume via their own template (which can expand {{cwd}}) and default to
        // a `.preserve` cwd policy, so keep the runtime cwd the agent was working in rather than the
        // launch dir. `.ignore` agents resume from the current directory, so the snapshot must carry
        // no saved cwd at all (downstream restore consumers read `workingDirectory` directly, not just
        // the command builder). The by-directory namespace below is only for built-in agents.
        if let registration {
            return registration.cwd == .ignore ? nil : (recordedCwd ?? launchCwd)
        }

        switch kind.cwdNamespacing {
        case .cwdInFile:
            // Resume is addressed by id and the cwd lives inside the record, so the runtime cwd is
            // fine — keeping it preserves the directory the agent was working in.
            return recordedCwd ?? launchCwd
        case .byDirectory:
            if kind == .claude,
               let verified = claudeVerifiedRestorableWorkingDirectory(
                   record: record,
                   recordedCwd: recordedCwd,
                   launchCwd: launchCwd,
                   fileManager: fileManager,
                   lookup: lookup
               ) {
                return verified
            }
            // The launch cwd matches the session namespace and never drifts; fall back to the
            // recorded cwd only when no launch cwd was captured.
            return launchCwd ?? recordedCwd
        }
    }

    /// For Claude, returns the candidate directory whose project folder actually holds the
    /// transcript — matched first against the transcript's known storage path, then against the
    /// config directory on disk — or `nil` when neither can be verified (so the caller prefers the
    /// launch cwd instead of the drift-prone recorded cwd).
    private static func claudeVerifiedRestorableWorkingDirectory(
        record: RestorableAgentHookSessionRecord,
        recordedCwd: String?,
        launchCwd: String?,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> String? {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        let candidates = [launchCwd, recordedCwd].compactMap { $0 }

        // The transcript's own storage path names the project directory Claude will look in,
        // so the candidate whose encoding matches it is the one Claude can resume from.
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            let projectDir = (expandedTranscriptPath as NSString).deletingLastPathComponent
            let expectedProjectDirName = (projectDir as NSString).lastPathComponent
            if !expectedProjectDirName.isEmpty,
               let matched = candidates.first(where: {
                   encodeClaudeProjectDir($0) == expectedProjectDirName
               }) {
                return matched
            }
        }

        // Probe the config directory for the candidate that holds the transcript on disk.
        let roots = lookup.configRoots(for: record)
        if !roots.isEmpty {
            for candidate in candidates {
                let projectDirName = encodeClaudeProjectDir(candidate)
                for root in roots where claudeTranscriptFileExists(
                    configRoot: root,
                    projectDirName: projectDirName,
                    sessionId: sessionId,
                    fileManager: fileManager
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    static func encodeClaudeProjectDir(_ path: String) -> String {
        // Claude derives a project directory name by replacing both "/" and "." with "-"
        // (e.g. "/Users/x/repo/.claude" -> "-Users-x-repo--claude"). Missing the "." case
        // sent dotted paths to the wrong project directory.
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func claudeTranscriptFileExists(
        configRoot: String,
        projectDirName: String,
        sessionId: String,
        fileManager: FileManager
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirName)
        let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        return regularNonEmptyFileExists(atPath: path, fileManager: fileManager)
    }

    private static func claudeTranscriptFileExistsInAnyProject(
        configRoot: String,
        sessionId: String,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        for projectDir in lookup.projectDirs(configRoot: configRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: path, fileManager: fileManager) {
                return true
            }
        }
        return false
    }

    private final class ClaudeTranscriptLookupCache {
        private let homeDirectory: String
        private let fileManager: FileManager
        private var defaultRoots: [String]?
        private var projectDirsByConfigRoot: [String: [String]] = [:]

        init(homeDirectory: String, fileManager: FileManager) {
            self.homeDirectory = homeDirectory
            self.fileManager = fileManager
        }

        func configRoots(for record: RestorableAgentHookSessionRecord) -> [String] {
            if let configured = RestorableAgentSessionIndex.normalizedNonEmptyValue(
                record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
            ) {
                return [
                    ClaudeConfigDirectoryPath.preferredPath(
                        configured,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory
                    ),
                ]
            }

            if let defaultRoots {
                return defaultRoots
            }

            var roots: [String] = []
            var seen: Set<String> = []
            func appendRoot(_ path: String) {
                let standardized = (path as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { return }
                roots.append(standardized)
            }

            let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
            if directoryExists(atPath: accountRoot),
               let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
                for accountDir in accountDirs.sorted() {
                    appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
                }
            }
            appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
            appendRoot(
                ClaudeConfigDirectoryPath.preferredPath(
                    (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                )
            )

            defaultRoots = roots
            return roots
        }

        func projectDirs(configRoot: String) -> [String] {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            if let cached = projectDirsByConfigRoot[standardizedRoot] {
                return cached
            }

            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot),
                  let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
                projectDirsByConfigRoot[standardizedRoot] = []
                return []
            }

            projectDirsByConfigRoot[standardizedRoot] = projectDirs
            return projectDirs
        }

        private func directoryExists(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func liveScopedProcessID(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        workspaceId: UUID,
        panelId: UUID,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        guard let pid = record.pid else {
            return nil
        }
        guard pid > 0,
              let process = processArgumentsProvider(pid),
              process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId) else {
            return nil
        }

        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return nil
        }

        guard let recordedExecutable = recordedExecutableBasename(record),
              let liveExecutable = process.arguments.first.map(executableBasename) else {
            return pid
        }
        guard liveProcessExecutableMatchesRecordedAgent(
            kind: kind,
            liveExecutable: liveExecutable,
            recordedExecutable: recordedExecutable,
            arguments: process.arguments
        ) else {
            return nil
        }
        return pid
    }

    private static func liveProcessExecutableMatchesRecordedAgent(
        kind: RestorableAgentKind,
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }

        guard kind == .claude else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return executableBasename(argument).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    private static func recordedExecutableBasename(_ record: RestorableAgentHookSessionRecord) -> String? {
        let executable = normalizedProcessValue(record.launchCommand?.executablePath)
            ?? normalizedProcessValue(record.launchCommand?.arguments.first)
        return executable.map(executableBasename)
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private static func normalizedProcessValue(_ value: String?) -> String? {
        normalizedNonEmptyValue(value)
    }

    private static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

}
