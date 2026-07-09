import Foundation
import CMUXAgentLaunch
import CmuxWorkspaces

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
        // KERN_PROCARGS2 argv/env decoding is the expensive unit of this scan;
        // memoize so the OpenCode, built-in, fallback, and registry passes read
        // each pid once. updateValue keeps nil misses cached instead of removing them.
        var processArgumentsByPID: [Int: CmuxTopProcessArguments?] = [:]
        func cachedProcessArguments(_ processID: Int) -> CmuxTopProcessArguments? {
            if let cached = processArgumentsByPID[processID] { return cached }
            let resolved = processArgumentsProvider(processID)
            processArgumentsByPID.updateValue(resolved, forKey: processID)
            return resolved
        }

        let scopedProcessIDsByPanelKey = processSnapshot.cmuxScopedProcessIDsByPanelKey()
        var resolved = VaultOpenCodeProcessScanner(fileManager: fileManager).processDetectedSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey,
            processArgumentsProvider: cachedProcessArguments
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
            processArgumentsProvider: cachedProcessArguments
        ) where resolved[key] == nil {
            resolved[key] = entry
        }
        resolved.merge(processDetectedForkParentFallbackSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey,
            processArgumentsProvider: cachedProcessArguments
        )) { existing, _ in existing }

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
                  let processArguments = cachedProcessArguments(process.pid) else {
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
                agentProcessIDs: [process.pid],
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
            let processID: Int
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
                processID: process.pid,
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
                agentProcessIDs: [candidate.processID],
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
