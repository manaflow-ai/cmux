import Foundation
import CMUXAgentLaunch
import SQLite3

extension RestorableAgentSessionIndex {
    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        return processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
    }

    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        return processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            processArgumentsProvider: { CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0) }
        )
    }

    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        let scopedProcessIDsByPanelKey = processSnapshot.cmuxScopedProcessIDsByPanelKey()
        var resolved = processDetectedOpenCodeSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey
        )

        // Built-in claude/codex have no Vault registration, so detect them
        // directly here — this makes hook-less sessions (e.g. `sr claude` /
        // direct `codex`, which bypass the cmux wrapper's session hook) still
        // fork-able. Don't overwrite a more-specific opencode/custom match.
        for (key, entry) in processDetectedClaudeCodexSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey,
            processArgumentsProvider: processArgumentsProvider
        ) where resolved[key] == nil {
            resolved[key] = entry
        }

        guard !registry.registrations.isEmpty else { return resolved }
        var registriesByWorkingDirectory: [String: CmuxVaultAgentRegistry] = [:]

        func registryForWorkingDirectory(_ workingDirectory: String?) -> CmuxVaultAgentRegistry {
            guard let workingDirectory else { return registry }
            let key = (workingDirectory as NSString).standardizingPath
            if let cached = registriesByWorkingDirectory[key] {
                return cached
            }
            let resolved = registry.mergingProjectConfig(
                workingDirectory: key,
                fileManager: fileManager
            )
            registriesByWorkingDirectory[key] = resolved
            return resolved
        }

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let processArguments = processArgumentsProvider(process.pid) else {
                continue
            }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            let cwd = normalized(observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"])
            let processRegistry = registryForWorkingDirectory(cwd)
            guard let registration = processRegistry.registrations.first(where: { $0.detect.matches(observed) }),
                  let sessionIDResolution = registration.sessionIdSource.sessionIDResolution(
                      from: observed,
                      registration: registration,
                      fileManager: fileManager
                  ) else {
                continue
            }
            let sessionId = sessionIDResolution.sessionId

            let executablePath = normalized(observed.arguments.first) ?? normalized(process.path) ?? registration.defaultExecutable
            let arguments = observed.arguments.isEmpty ? [executablePath] : observed.arguments
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .custom(registration.id),
                sessionId: sessionId,
                workingDirectory: registration.cwd == .ignore ? nil : cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: registration.id,
                    executablePath: executablePath,
                    arguments: arguments,
                    workingDirectory: cwd,
                    environment: observed.environment
                ),
                registration: registration
            )
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            resolved[key] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [],
                sessionIDSource: sessionIDResolution.source
            )
        }

        return resolved
    }

    // MARK: - Built-in claude/codex live-process detection

    /// Detects CMUX-scoped live `claude`/`codex` processes that cmux never
    /// recorded a session hook for (e.g. launched through `sr`, bypassing the
    /// cmux wrapper that injects the SessionStart hook), and resolves a fork-able
    /// snapshot by reading the agent's on-disk transcript/rollout. An inferred
    /// (newest-on-disk) session id is only attributed when exactly one same-kind
    /// process shares the cwd, so an ambiguous cwd never forks the wrong session.
    static func processDetectedClaudeCodexSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        struct Candidate {
            let panelKey: PanelKey
            let kind: RestorableAgentKind
            let observed: VaultObservedAgentProcess
            let cwd: String?
            let cwdKey: String
            let explicitSessionId: String?
        }

        var candidates: [Candidate] = []
        var panelsByKindAndCwd: [String: Set<PanelKey>] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let processArguments = processArgumentsProvider(process.pid) else {
                continue
            }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            let kind: RestorableAgentKind
            if observed.isClaudeProcess {
                kind = .claude
            } else if observed.isCodexProcess {
                kind = .codex
            } else {
                continue
            }
            // The hook dispatch shell (`sh -c …`) inherits CMUX scope; the
            // positive kind match already excludes `sr`/wrappers, but guard the
            // shell-dispatcher argv form explicitly too.
            guard !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(observed.arguments) else {
                continue
            }
            let cwd = normalized(observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"])
            // Group by the symlink-canonical path (not `standardizingPath`, which
            // does not resolve arbitrary symlinks) so two panels whose cwds are
            // different spellings of the same real directory collapse into one
            // group — otherwise the single-panel ambiguity guard is bypassed and
            // both could infer the same session. Resolution normalizes the same
            // way (codex via RovoDevIndex.normalizedPath), so the guard and the
            // resolved target stay consistent. The snapshot keeps the literal cwd.
            let cwdKey = cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
            let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
            candidates.append(Candidate(
                panelKey: panelKey,
                kind: kind,
                observed: observed,
                cwd: cwd,
                cwdKey: cwdKey,
                explicitSessionId: explicitProcessSessionId(kind: kind, arguments: observed.arguments)
            ))
            panelsByKindAndCwd[kind.rawValue + "\u{1f}" + cwdKey, default: []].insert(panelKey)
        }

        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]
        var inferredSessionByKindAndCwd: [String: String?] = [:]

        for candidate in candidates {
            let sessionId: String
            let source: ProcessDetectedSessionIDSource
            if let explicit = candidate.explicitSessionId {
                sessionId = explicit
                source = .explicit
            } else {
                let kindCwdKey = candidate.kind.rawValue + "\u{1f}" + candidate.cwdKey
                guard (panelsByKindAndCwd[kindCwdKey]?.count ?? 0) == 1,
                      let cwd = candidate.cwd else {
                    continue
                }
                let inferred: String?
                if let cached = inferredSessionByKindAndCwd[kindCwdKey] {
                    inferred = cached
                } else {
                    inferred = inferredProcessSessionId(
                        kind: candidate.kind,
                        cwd: cwd,
                        environment: candidate.observed.environment,
                        fileManager: fileManager
                    )
                    inferredSessionByKindAndCwd[kindCwdKey] = inferred
                }
                guard let inferred else { continue }
                sessionId = inferred
                source = .inferredLatestSessionFile
            }

            // A panel can have several matching processes (the agent plus a node
            // worker); keep an explicit-id snapshot over an inferred one.
            if let existing = resolved[candidate.panelKey],
               existing.sessionIDSource == .explicit,
               source != .explicit {
                continue
            }

            let executablePath = normalized(candidate.observed.arguments.first)
                ?? normalized(candidate.observed.processPath)
            let arguments = candidate.observed.arguments.isEmpty
                ? [executablePath].compactMap { $0 }
                : candidate.observed.arguments
            let snapshot = SessionRestorableAgentSnapshot(
                kind: candidate.kind,
                sessionId: sessionId,
                workingDirectory: candidate.cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: candidate.kind.rawValue,
                    executablePath: executablePath,
                    arguments: arguments,
                    workingDirectory: candidate.cwd,
                    environment: candidate.observed.environment
                )
            )
            resolved[candidate.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[candidate.panelKey] ?? [],
                sessionIDSource: source
            )
        }

        return resolved
    }

    private static func inferredProcessSessionId(
        kind: RestorableAgentKind,
        cwd: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        switch kind {
        case .claude:
            return RestorableAgentSessionIndex.newestClaudeSessionId(
                forCwd: cwd,
                configDir: environment["CLAUDE_CONFIG_DIR"],
                fileManager: fileManager
            )
        case .codex:
            return CodexSessionResolver(fileManager: fileManager).inferredCodexSessionId(
                cwd: cwd,
                env: environment
            )
        default:
            return nil
        }
    }

    private static func explicitProcessSessionId(
        kind: RestorableAgentKind,
        arguments: [String]
    ) -> String? {
        let argvParser = AgentResumeArgvParser()
        switch kind {
        case .claude:
            return argvParser.claudeExplicitResumeSessionId(in: arguments)
        case .codex:
            return argvParser.codexExplicitResumeSessionId(in: arguments)
        default:
            return nil
        }
    }

    private static func processDetectedOpenCodeSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>]
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        let openCodeResolver = OpenCodeProcessResolver()
        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]
        var sessionByWorkingDirectoryAndParent: [String: String] = [:]
        var sessionMissesByWorkingDirectoryAndParent = Set<String>()
        var openCodeProcesses: [
            (
                panelKey: PanelKey,
                observed: VaultObservedAgentProcess,
                environment: [String: String],
                workingDirectory: String?,
                workingDirectoryKey: String
            )
        ] = []
        var panelKeysByWorkingDirectory: [String: Set<PanelKey>] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let processArguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process.pid) else {
                continue
            }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isOpenCodeProcess else { continue }

            let cwd = openCodeResolver.workingDirectory(observed: observed)
            let cwdKey = cwd.map { ($0 as NSString).standardizingPath } ?? ""
            let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
            openCodeProcesses.append((
                panelKey: panelKey,
                observed: observed,
                environment: processArguments.environment,
                workingDirectory: cwd,
                workingDirectoryKey: cwdKey
            ))
            panelKeysByWorkingDirectory[cwdKey, default: []].insert(panelKey)
        }

        for process in openCodeProcesses {
            let sameWorkingDirectoryPanelCount = panelKeysByWorkingDirectory[process.workingDirectoryKey]?.count ?? 0
            let argvParser = AgentResumeArgvParser()
            let hasForkFlag = argvParser.hasOpenCodeForkFlag(in: process.observed.arguments)
            let forkParentSessionId = argvParser.openCodeForkParentSessionId(in: process.observed.arguments)
                ?? (hasForkFlag ? argvParser.value(in: process.observed.arguments, afterOption: "--session") : nil)
            let latestSessionId: String?
            let sessionCacheKey = process.workingDirectoryKey + "\u{1f}" + (forkParentSessionId ?? "")
            if !hasForkFlag || forkParentSessionId == nil || sameWorkingDirectoryPanelCount != 1 || process.workingDirectory == nil {
                latestSessionId = nil
            } else if let cached = sessionByWorkingDirectoryAndParent[sessionCacheKey] {
                latestSessionId = cached
            } else if sessionMissesByWorkingDirectoryAndParent.contains(sessionCacheKey) {
                latestSessionId = nil
            } else {
                latestSessionId = latestOpenCodeSessionId(
                    workingDirectory: process.workingDirectory,
                    parentSessionId: forkParentSessionId,
                    fileManager: fileManager
                )
                if let latestSessionId {
                    sessionByWorkingDirectoryAndParent[sessionCacheKey] = latestSessionId
                } else {
                    sessionMissesByWorkingDirectoryAndParent.insert(sessionCacheKey)
                }
            }
            guard let sessionId = openCodeResolver.fallbackSessionId(
                arguments: process.observed.arguments,
                latestSessionIdForSolePanel: latestSessionId,
                sameWorkingDirectoryPanelCount: sameWorkingDirectoryPanelCount
            ) else { continue }

            let executablePath = openCodeResolver.executablePath(
                observed: process.observed,
                environment: process.environment
            )
            guard let launchArguments = openCodeResolver.launchArguments(
                observed: process.observed,
                executablePath: executablePath
            ) else { continue }
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .opencode,
                sessionId: sessionId,
                workingDirectory: process.workingDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: "opencode",
                    executablePath: executablePath,
                    arguments: launchArguments,
                    workingDirectory: process.workingDirectory,
                    environment: process.observed.environment
                )
            )
            resolved[process.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[process.panelKey] ?? [],
                sessionIDSource: .explicit
            )
        }

        return resolved
    }

    private static func latestOpenCodeSessionId(
        workingDirectory: String?,
        parentSessionId: String?,
        fileManager: FileManager
    ) -> String? {
        let snapshot: OpenCodeDatabaseSnapshot.Snapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(prefix: "cmux-opencode-process") else {
                return nil
            }
            snapshot = madeSnapshot
        } catch {
            return nil
        }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        guard let parentId = normalized(parentSessionId) else {
            return nil
        }
        guard let cwd = normalized(workingDirectory).map({ ($0 as NSString).standardizingPath }) else {
            return nil
        }
        let sql = """
            SELECT id FROM session
            WHERE directory = ?
              AND parent_id = ?
            ORDER BY time_updated DESC
            LIMIT 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, cwd, -1, SQLITE_TRANSIENT_FN)
        bindIndex += 1
        sqlite3_bind_text(stmt, bindIndex, parentId, -1, SQLITE_TRANSIENT_FN)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let sessionId = SessionIndexStore.sqliteText(stmt, 0),
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

extension SurfaceResumeBindingIndex {
    static func processDetectedTmuxBindings(
        fileManager: FileManager
    ) -> [PanelKey: (binding: SurfaceResumeBindingSnapshot, updatedAt: TimeInterval)] {
        _ = fileManager
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        return processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
    }

    static func processDetectedTmuxBindings(
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval
    ) -> [PanelKey: (binding: SurfaceResumeBindingSnapshot, updatedAt: TimeInterval)] {
        _ = fileManager
        var resolved: [PanelKey: (binding: SurfaceResumeBindingSnapshot, updatedAt: TimeInterval)] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  process.isTerminalForegroundProcessGroup,
                  let processArguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process.pid) else {
                continue
            }
            guard let binding = TmuxResumeParser.binding(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment,
                capturedAt: capturedAt
            ) else {
                continue
            }
            resolved[PanelKey(workspaceId: workspaceId, panelId: panelId)] = (binding: binding, updatedAt: capturedAt)
        }

        return resolved
    }

    static func tmuxResumeBindingForTesting(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String],
        capturedAt: TimeInterval = 1_777_777_777
    ) -> SurfaceResumeBindingSnapshot? {
        TmuxResumeParser.binding(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment,
            capturedAt: capturedAt
        )
    }
}
