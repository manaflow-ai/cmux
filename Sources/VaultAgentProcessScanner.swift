import Foundation
import CMUXAgentLaunch
import SQLite3

struct RestorableAgentProcessDetectionScope: Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let ttyName: String?
    let ttyDevice: Int64?

    init(workspaceId: UUID, panelId: UUID, ttyName: String?) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        let trimmedTTYName = ttyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ttyName = trimmedTTYName?.isEmpty == false && trimmedTTYName != "not a tty" ? trimmedTTYName : nil
        self.ttyDevice = nil
    }

    init(workspaceId: UUID, panelId: UUID, ttyDevice: Int64) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.ttyName = nil
        self.ttyDevice = ttyDevice
    }
}

enum RestorableAgentProcessDetectionCandidateSource {
    case cmuxScoped
    case fallbackScope
}

struct RestorableAgentProcessDetectionCandidate {
    let panelKey: RestorableAgentSessionIndex.PanelKey
    let process: CmuxTopProcessInfo
    let arguments: CmuxTopProcessArguments
    let source: RestorableAgentProcessDetectionCandidateSource
    let matchesFallbackScope: Bool
}

extension CmuxTopProcessInfo {
    var hasForegroundProcessStatus: Bool {
        processGroupID != nil && terminalProcessGroupID != nil
    }

    var isForegroundProcess: Bool {
        guard let processGroupID,
              let terminalProcessGroupID else {
            return false
        }
        return processGroupID == terminalProcessGroupID
    }

    var canBeActiveAgentProcess: Bool {
        !hasForegroundProcessStatus || isForegroundProcess
    }
}

extension AgentLaunchCommandSnapshot {
    init(
        processDetectedLauncher launcher: String,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) {
        var selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        if launcher == "opencode",
           let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            selectedEnvironment["PATH"] = path
        }
        self.init(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: selectedEnvironment.isEmpty ? nil : selectedEnvironment,
            capturedAt: nil,
            source: "process"
        )
    }
}

extension RestorableAgentSessionIndex {
    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager,
        fallbackScope: RestorableAgentProcessDetectionScope? = nil,
        processSnapshot: CmuxTopProcessSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false),
        processArguments: (Int) -> CmuxTopProcessArguments? = CmuxTopProcessSnapshot.processArgumentsAndEnvironment,
        processOpenFilePaths: (Int) -> [String] = CmuxTopProcessSnapshot.processOpenFilePaths,
        latestOpenCodeSessionId: (String?, String?, FileManager) -> String? = RestorableAgentSessionIndex.latestOpenCodeSessionId,
        latestCodexForkSessionId: (String?, String, [String: String], FileManager) -> String? = RestorableAgentSessionIndex.latestCodexForkSessionId
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        let capturedAt = Date().timeIntervalSince1970
        let candidates = processDetectionCandidates(
            processSnapshot: processSnapshot,
            fallbackScope: fallbackScope,
            processArguments: processArguments
        )
        var resolved = processDetectedClaudeSnapshots(
            candidates: candidates,
            capturedAt: capturedAt,
            fileManager: fileManager
        )
        for (key, value) in processDetectedCodexSnapshots(
            candidates: candidates,
            capturedAt: capturedAt,
            fileManager: fileManager,
            processOpenFilePaths: processOpenFilePaths,
            latestCodexForkSessionId: latestCodexForkSessionId
        ) {
            if let existing = resolved[key] {
                if processDetectionShouldPreferBuiltin(
                    .codex,
                    over: existing.snapshot.kind,
                    panelKey: key,
                    candidates: candidates
                ) {
                    sentryBreadcrumb(
                        "session.process_detected.builtin_conflict",
                        category: "session.restore",
                        data: ["kept": "codex", "dropped": existing.snapshot.kind.rawValue]
                    )
                    resolved[key] = value
                    continue
                }
                sentryBreadcrumb(
                    "session.process_detected.builtin_conflict",
                    category: "session.restore",
                    data: ["kept": existing.snapshot.kind.rawValue, "dropped": "codex"]
                )
                continue
            }
            resolved[key] = value
        }
        for (key, value) in processDetectedOpenCodeSnapshots(
            candidates: candidates,
            capturedAt: capturedAt,
            fileManager: fileManager,
            latestOpenCodeSessionId: latestOpenCodeSessionId
        ) {
            if let existing = resolved[key] {
                if processDetectionShouldPreferBuiltin(
                    .opencode,
                    over: existing.snapshot.kind,
                    panelKey: key,
                    candidates: candidates
                ) {
                    sentryBreadcrumb(
                        "session.process_detected.builtin_conflict",
                        category: "session.restore",
                        data: ["kept": "opencode", "dropped": existing.snapshot.kind.rawValue]
                    )
                    resolved[key] = value
                    continue
                }
                sentryBreadcrumb(
                    "session.process_detected.builtin_conflict",
                    category: "session.restore",
                    data: ["kept": existing.snapshot.kind.rawValue, "dropped": "opencode"]
                )
                continue
            }
            resolved[key] = value
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

        var selectedRegisteredCandidateByPanelKey: [
            PanelKey: (source: RestorableAgentProcessDetectionCandidateSource, isForeground: Bool, matchesFallbackScope: Bool)
        ] = [:]
        for candidate in candidates {
            let process = candidate.process
            let processArguments = candidate.arguments
            guard process.canBeActiveAgentProcess else { continue }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            let cwd = normalized(observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"])
            let processRegistry = registryForWorkingDirectory(cwd)
            guard let registration = processRegistry.registrations.first(where: { $0.detect.matches(observed) }),
                  let sessionId = registration.sessionIdSource.sessionId(
                      from: observed,
                      registration: registration,
                      fileManager: fileManager
                  ) else {
                continue
            }

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
            if let existing = selectedRegisteredCandidateByPanelKey[candidate.panelKey],
               !processDetectionShouldReplaceCandidate(
                   existing: existing,
                   candidate: (
                       source: candidate.source,
                       isForeground: process.isForegroundProcess,
                       matchesFallbackScope: candidate.matchesFallbackScope
                   )
               ) {
                continue
            }
            resolved[candidate.panelKey] = (snapshot: snapshot, updatedAt: capturedAt)
            selectedRegisteredCandidateByPanelKey[candidate.panelKey] = (
                source: candidate.source,
                isForeground: process.isForegroundProcess,
                matchesFallbackScope: candidate.matchesFallbackScope
            )
        }

        return resolved
    }

    static func processDetectionShouldReplaceCandidate(
        existing: (source: RestorableAgentProcessDetectionCandidateSource, isForeground: Bool, matchesFallbackScope: Bool),
        candidate: (source: RestorableAgentProcessDetectionCandidateSource, isForeground: Bool, matchesFallbackScope: Bool)
    ) -> Bool {
        if existing.source == .cmuxScoped,
           candidate.source != .cmuxScoped {
            return false
        }
        if existing.source != .cmuxScoped,
           candidate.source == .cmuxScoped {
            return true
        }
        if existing.matchesFallbackScope,
           !candidate.matchesFallbackScope {
            return false
        }
        if !existing.matchesFallbackScope,
           candidate.matchesFallbackScope {
            return true
        }
        if existing.isForeground,
           !candidate.isForeground {
            return false
        }
        if !existing.isForeground,
           candidate.isForeground {
            return true
        }
        return true
    }

    private static func processDetectionShouldPreferBuiltin(
        _ candidateKind: RestorableAgentKind,
        over existingKind: RestorableAgentKind,
        panelKey: PanelKey,
        candidates: [RestorableAgentProcessDetectionCandidate]
    ) -> Bool {
        guard let selectedCandidate = processDetectionSelectedBuiltinPriority(
            kind: candidateKind,
            panelKey: panelKey,
            candidates: candidates
        ) else {
            return false
        }
        guard let selectedExisting = processDetectionSelectedBuiltinPriority(
            kind: existingKind,
            panelKey: panelKey,
            candidates: candidates
        ) else {
            return true
        }
        if selectedCandidate.source == selectedExisting.source,
           selectedCandidate.matchesFallbackScope == selectedExisting.matchesFallbackScope,
           selectedCandidate.isForeground == selectedExisting.isForeground {
            return false
        }
        return processDetectionShouldReplaceCandidate(
            existing: selectedExisting,
            candidate: selectedCandidate
        )
    }

    private static func processDetectionSelectedBuiltinPriority(
        kind: RestorableAgentKind,
        panelKey: PanelKey,
        candidates: [RestorableAgentProcessDetectionCandidate]
    ) -> (
        source: RestorableAgentProcessDetectionCandidateSource,
        isForeground: Bool,
        matchesFallbackScope: Bool
    )? {
        var selected: (
            source: RestorableAgentProcessDetectionCandidateSource,
            isForeground: Bool,
            matchesFallbackScope: Bool
        )?
        for candidate in candidates where candidate.panelKey == panelKey {
            guard processDetectionBuiltinKind(candidate) == kind else { continue }
            let priority = (
                source: candidate.source,
                isForeground: candidate.process.isForegroundProcess,
                matchesFallbackScope: candidate.matchesFallbackScope
            )
            if let existing = selected {
                if processDetectionShouldReplaceCandidate(existing: existing, candidate: priority) {
                    selected = priority
                }
            } else {
                selected = priority
            }
        }
        return selected
    }

    private static func processDetectionBuiltinKind(
        _ candidate: RestorableAgentProcessDetectionCandidate
    ) -> RestorableAgentKind? {
        let observed = VaultObservedAgentProcess(
            processName: candidate.process.name,
            processPath: candidate.process.path,
            arguments: candidate.arguments.arguments,
            environment: candidate.arguments.environment
        )
        if observed.isOpenCodeProcess {
            return .opencode
        }
        if observed.isCodexProcess {
            return .codex
        }
        if observed.isClaudeProcess {
            return .claude
        }
        return nil
    }

    private static func processDetectionCandidates(
        processSnapshot: CmuxTopProcessSnapshot,
        fallbackScope: RestorableAgentProcessDetectionScope?,
        processArguments: (Int) -> CmuxTopProcessArguments?
    ) -> [RestorableAgentProcessDetectionCandidate] {
        var candidates: [RestorableAgentProcessDetectionCandidate] = []
        var seenPIDs = Set<Int>()
        var scopedPanelKeysByPID: [Int: PanelKey] = [:]
        let fallbackScopedPIDs: Set<Int>? = {
            guard let fallbackScope,
                  fallbackScope.ttyDevice != nil || fallbackScope.ttyName != nil else {
                return nil
            }
            let fallbackProcesses = processDetectionFallbackProcesses(
                processSnapshot: processSnapshot,
                fallbackScope: fallbackScope
            )
            guard !fallbackProcesses.isEmpty else { return nil }
            return Set(fallbackProcesses.map(\.pid))
        }()

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let arguments = processArguments(process.pid) else {
                continue
            }
            seenPIDs.insert(process.pid)
            let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
            scopedPanelKeysByPID[process.pid] = panelKey
            candidates.append(
                RestorableAgentProcessDetectionCandidate(
                    panelKey: panelKey,
                    process: process,
                    arguments: arguments,
                    source: .cmuxScoped,
                    matchesFallbackScope: fallbackScopedPIDs?.contains(process.pid) ?? false
                )
            )
        }

        guard let fallbackScope else { return candidates }
        let fallbackProcesses = processDetectionFallbackProcesses(
            processSnapshot: processSnapshot,
            fallbackScope: fallbackScope
        )
        let fallbackPanelKey = PanelKey(workspaceId: fallbackScope.workspaceId, panelId: fallbackScope.panelId)
        for process in fallbackProcesses {
            let scopedPanelKey = scopedPanelKeysByPID[process.pid]
            if scopedPanelKey == fallbackPanelKey {
                continue
            }
            guard !seenPIDs.contains(process.pid) || scopedPanelKeysByPID[process.pid] != nil else {
                continue
            }
            let canUseFallbackScope = scopedPanelKey != nil
                ? process.canBeActiveAgentProcess
                : processMatchesFallbackScope(process, fallbackScope: fallbackScope)
            guard canUseFallbackScope,
                  let arguments = processArguments(process.pid) else {
                continue
            }
            seenPIDs.insert(process.pid)
            candidates.append(
                RestorableAgentProcessDetectionCandidate(
                    panelKey: fallbackPanelKey,
                    process: process,
                    arguments: arguments,
                    source: .fallbackScope,
                    matchesFallbackScope: true
                )
            )
        }

        return candidates
    }

    private static func processDetectionFallbackProcesses(
        processSnapshot: CmuxTopProcessSnapshot,
        fallbackScope: RestorableAgentProcessDetectionScope
    ) -> [CmuxTopProcessInfo] {
        if let ttyDevice = fallbackScope.ttyDevice {
            return processSnapshot.processes(forTTYDevice: ttyDevice)
        }
        guard let ttyName = fallbackScope.ttyName else {
            return []
        }
        return processSnapshot.processes(forTTYName: ttyName)
    }

    private static func processMatchesFallbackScope(
        _ process: CmuxTopProcessInfo,
        fallbackScope: RestorableAgentProcessDetectionScope
    ) -> Bool {
        if let workspaceId = process.cmuxWorkspaceID,
           workspaceId != fallbackScope.workspaceId {
            return false
        }
        if let panelId = process.cmuxSurfaceID,
           panelId != fallbackScope.panelId {
            return false
        }
        guard process.canBeActiveAgentProcess else { return false }
        return true
    }

    static func processLooksLikeOpenCode(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> Bool {
        VaultObservedAgentProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: [:]
        ).isOpenCodeProcess
    }

    static func openCodeExecutablePathForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        return openCodeExecutablePath(observed: observed, environment: environment)
    }

    static func openCodeLaunchArgumentsForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> [String]? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        let executablePath = openCodeExecutablePath(observed: observed, environment: environment)
        return openCodeLaunchArguments(observed: observed, executablePath: executablePath)
    }

    static func openCodeWorkingDirectoryForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        return openCodeWorkingDirectory(observed: observed)
    }

    static func openCodeFallbackSessionIdForProcess(
        arguments: [String],
        latestSessionIdForSolePanel: String?,
        sameWorkingDirectoryPanelCount: Int
    ) -> String? {
        if arguments.hasOpenCodeForkFlag {
            let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s")
            let assignedForkParentSessionId = arguments.openCodeForkParentSessionId
            if let explicitSessionId,
               let assignedForkParentSessionId,
               explicitSessionId != assignedForkParentSessionId {
                return explicitSessionId
            }
            guard sameWorkingDirectoryPanelCount == 1 else { return nil }
            guard let latestSessionIdForSolePanel else { return nil }
            let forkParentSessionId = assignedForkParentSessionId ?? explicitSessionId
            guard let forkParentSessionId else { return nil }
            guard forkParentSessionId != latestSessionIdForSolePanel else { return nil }
            return latestSessionIdForSolePanel
        }
        if let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s") {
            return explicitSessionId
        }
        return nil
    }

    static func processLooksLikeCodex(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> Bool {
        VaultObservedAgentProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: [:]
        ).isCodexProcess
    }

    static func codexSessionIdForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        codexSessionId(tail: codexLaunchTail(
            observed: VaultObservedAgentProcess(
                processName: "",
                processPath: nil,
                arguments: arguments,
                environment: environment
            )
        ), environment: environment)
    }

    static func codexLaunchArgumentsForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> [String]? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        let executablePath = codexExecutablePath(observed: observed, environment: environment)
        return codexLaunchArguments(observed: observed, executablePath: executablePath)
    }

    private static func processDetectedCodexSnapshots(
        candidates: [RestorableAgentProcessDetectionCandidate],
        capturedAt: TimeInterval,
        fileManager: FileManager,
        processOpenFilePaths: (Int) -> [String],
        latestCodexForkSessionId: (String?, String, [String: String], FileManager) -> String?
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        var selectedCandidateByPanelKey: [
            PanelKey: (source: RestorableAgentProcessDetectionCandidateSource, isForeground: Bool, matchesFallbackScope: Bool)
        ] = [:]
        var forkMetadataPanelKeysByKey: [String: Set<PanelKey>] = [:]
        var forkMetadataPanelKeysByParentSessionId: [String: Set<PanelKey>] = [:]
        let fallbackRemappedPIDs = Set(candidates.filter { $0.source == .fallbackScope }.map(\.process.pid))

        for candidate in candidates {
            let process = candidate.process
            if candidate.source == .cmuxScoped,
               fallbackRemappedPIDs.contains(process.pid) {
                continue
            }
            let processArguments = candidate.arguments
            guard process.canBeActiveAgentProcess else { continue }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isCodexProcess else { continue }
            let tail = codexLaunchTail(observed: observed)
            guard let command = codexSessionCommand(in: tail),
                  command.name == "fork" else {
                continue
            }
            let workingDirectory = normalized(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            if let parentSessionId = normalized(command.sessionId) {
                forkMetadataPanelKeysByParentSessionId[parentSessionId, default: []].insert(candidate.panelKey)
            }
            guard let key = codexForkMetadataFallbackKey(
                workingDirectory: workingDirectory,
                parentSessionId: command.sessionId
            ) else {
                continue
            }
            forkMetadataPanelKeysByKey[key, default: []].insert(candidate.panelKey)
        }

        for candidate in candidates {
            let process = candidate.process
            let processArguments = candidate.arguments
            guard process.canBeActiveAgentProcess else { continue }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isCodexProcess else { continue }

            let tail = codexLaunchTail(observed: observed)
            let executablePath = codexExecutablePath(
                observed: observed,
                environment: processArguments.environment
            )
            let workingDirectory = normalized(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            let command = codexSessionCommand(in: tail)
            let parentForkSessionId = command.flatMap { normalized($0.sessionId) }
            let openFilePaths = command?.name == "resume" ? [] : processOpenFilePaths(process.pid)
            let canUseForkMetadataFallback = command?.name == "fork"
                && codexForkMetadataFallbackKey(
                    workingDirectory: workingDirectory,
                    parentSessionId: command?.sessionId
                ).map { forkMetadataPanelKeysByKey[$0]?.count == 1 } == true
                && parentForkSessionId.map { forkMetadataPanelKeysByParentSessionId[$0]?.count == 1 } == true
            guard let sessionResolution = codexSessionResolution(
                tail: tail,
                environment: processArguments.environment,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                openFilePaths: openFilePaths,
                latestCodexForkSessionId: latestCodexForkSessionId,
                allowCodexForkMetadataFallback: canUseForkMetadataFallback
            ) else {
                continue
            }
            guard let launchCommand = codexLaunchCommand(
                observed: observed,
                executablePath: executablePath,
                tail: tail,
                workingDirectory: workingDirectory
            ) else {
                sentryBreadcrumb(
                    "session.process_detected.codex.skip",
                    category: "session.restore",
                    data: ["pid": process.pid, "reason": "sanitize_failed"]
                )
                continue
            }
            let isForeground = process.isForegroundProcess
            if let existing = selectedCandidateByPanelKey[candidate.panelKey] {
                if !processDetectionShouldReplaceCandidate(
                    existing: existing,
                    candidate: (
                        source: candidate.source,
                        isForeground: isForeground,
                        matchesFallbackScope: candidate.matchesFallbackScope
                    )
                ) {
                    continue
                }
            }
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionResolution.sessionId,
                workingDirectory: workingDirectory,
                launchCommand: launchCommand
            )
            resolved[candidate.panelKey] = (
                snapshot: snapshot,
                updatedAt: sessionResolution.isForkParentFallback ? 0 : capturedAt
            )
            selectedCandidateByPanelKey[candidate.panelKey] = (
                source: candidate.source,
                isForeground: isForeground,
                matchesFallbackScope: candidate.matchesFallbackScope
            )
        }

        return resolved
    }

    private static func codexSessionId(
        tail: [String],
        environment: [String: String]
    ) -> String? {
        codexSessionId(
            tail: tail,
            environment: environment,
            workingDirectory: normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"]),
            fileManager: .default,
            latestCodexForkSessionId: RestorableAgentSessionIndex.latestCodexForkSessionId
        )
    }

    private struct CodexSessionResolution {
        let sessionId: String
        let isForkParentFallback: Bool
    }

    private static func codexSessionId(
        tail: [String],
        environment: [String: String],
        workingDirectory: String?,
        fileManager: FileManager,
        openFilePaths: [String] = [],
        latestCodexForkSessionId: (String?, String, [String: String], FileManager) -> String?,
        allowCodexForkMetadataFallback: Bool = true
    ) -> String? {
        codexSessionResolution(
            tail: tail,
            environment: environment,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            openFilePaths: openFilePaths,
            latestCodexForkSessionId: latestCodexForkSessionId,
            allowCodexForkMetadataFallback: allowCodexForkMetadataFallback
        )?.sessionId
    }

    private static func codexSessionResolution(
        tail: [String],
        environment: [String: String],
        workingDirectory: String?,
        fileManager: FileManager,
        openFilePaths: [String] = [],
        latestCodexForkSessionId: (String?, String, [String: String], FileManager) -> String?,
        allowCodexForkMetadataFallback: Bool = true
    ) -> CodexSessionResolution? {
        if let command = codexSessionCommand(in: tail),
           command.name == "resume" || command.name == "fork" {
            let commandSessionId = command.sessionId
            if command.name == "fork" {
                if let openSessionId = codexSessionIdFromOpenSessionFiles(
                    openFilePaths,
                    workingDirectory: workingDirectory,
                    parentSessionId: commandSessionId,
                    environment: environment,
                    fileManager: fileManager
                ) {
                    return CodexSessionResolution(sessionId: openSessionId, isForkParentFallback: false)
                }
                // Codex fork processes can inherit the parent CODEX_THREAD_ID.
                // Prefer the child id from rollout metadata when it exists so
                // a forked pane can be forked again from its own conversation.
                if allowCodexForkMetadataFallback,
                   let forkSessionId = latestCodexForkSessionId(
                       workingDirectory,
                       commandSessionId,
                       environment,
                       fileManager
                   ) {
                    return CodexSessionResolution(sessionId: forkSessionId, isForkParentFallback: false)
                }
                if let threadId = normalized(environment["CODEX_THREAD_ID"]),
                   threadId != commandSessionId {
                    return CodexSessionResolution(sessionId: threadId, isForkParentFallback: false)
                }
                if let sessionId = normalized(environment["CODEX_SESSION_ID"]),
                   sessionId != commandSessionId {
                    return CodexSessionResolution(sessionId: sessionId, isForkParentFallback: false)
                }
                return CodexSessionResolution(
                    sessionId: commandSessionId,
                    isForkParentFallback: true
                )
            }
            return CodexSessionResolution(sessionId: commandSessionId, isForkParentFallback: false)
        }
        if let openSessionId = codexSessionIdFromOpenSessionFiles(
            openFilePaths,
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager
        ) {
            return CodexSessionResolution(sessionId: openSessionId, isForkParentFallback: false)
        }
        if let threadId = normalized(environment["CODEX_THREAD_ID"]) {
            return CodexSessionResolution(sessionId: threadId, isForkParentFallback: false)
        }
        if let sessionId = normalized(environment["CODEX_SESSION_ID"]) {
            return CodexSessionResolution(sessionId: sessionId, isForkParentFallback: false)
        }
        return nil
    }

    private static func codexForkMetadataFallbackKey(
        workingDirectory: String?,
        parentSessionId: String?
    ) -> String? {
        guard let workingDirectory = standardizedPath(workingDirectory),
              let parentSessionId = normalized(parentSessionId) else {
            return nil
        }
        return workingDirectory + "\u{1f}" + parentSessionId
    }

    private static func codexSessionIdFromOpenSessionFiles(
        _ openFilePaths: [String],
        workingDirectory: String?,
        parentSessionId: String? = nil,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        let rawParentSessionId = parentSessionId
        let normalizedParentSessionId = rawParentSessionId.flatMap { normalized($0) }
        if rawParentSessionId != nil, normalizedParentSessionId == nil {
            return nil
        }
        let sessionsDirectory = codexHomeDirectory(environment: environment, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
            .path
        let sessionsDirectoryPrefix = sessionsDirectory.hasSuffix("/") ? sessionsDirectory : sessionsDirectory + "/"
        let standardizedWorkingDirectory = standardizedPath(workingDirectory)
        var selectedMatchingDirectory: (sessionId: String, createdAt: Date)?
        var selectedAnyDirectory: (sessionId: String, createdAt: Date)?

        for rawPath in openFilePaths {
            let fileURL = URL(
                fileURLWithPath: (rawPath as NSString).expandingTildeInPath,
                isDirectory: false
            ).standardizedFileURL
            guard fileURL.pathExtension == "jsonl",
                  fileURL.path.hasPrefix(sessionsDirectoryPrefix),
                  let meta = codexSessionMetaLine(fileURL: fileURL),
                  meta.type == nil || meta.type == "session_meta",
                  let payload = meta.payload,
                  let sessionId = normalized(payload.id) else {
                continue
            }
            if let normalizedParentSessionId {
                guard normalized(payload.forkedFromId) == normalizedParentSessionId,
                      sessionId != normalizedParentSessionId else {
                    continue
                }
            }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let createdAt = codexSessionCreatedAt(meta: meta) ?? values?.contentModificationDate ?? .distantPast
            if selectedAnyDirectory == nil || createdAt > selectedAnyDirectory!.createdAt {
                selectedAnyDirectory = (sessionId: sessionId, createdAt: createdAt)
            }
            guard let standardizedWorkingDirectory,
                  standardizedPath(payload.cwd) == standardizedWorkingDirectory else {
                continue
            }
            if selectedMatchingDirectory == nil || createdAt > selectedMatchingDirectory!.createdAt {
                selectedMatchingDirectory = (sessionId: sessionId, createdAt: createdAt)
            }
        }

        return (selectedMatchingDirectory ?? selectedAnyDirectory)?.sessionId
    }

    private struct CodexSessionMetaLine: Decodable {
        struct Payload: Decodable {
            let id: String?
            let cwd: String?
            let forkedFromId: String?

            enum CodingKeys: String, CodingKey {
                case id
                case cwd
                case forkedFromId = "forked_from_id"
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private static let codexSessionMetaReadLimit = 2 * 1024 * 1024

    static func latestCodexForkSessionId(
        workingDirectory: String?,
        parentSessionId: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        guard let parentSessionId = normalized(parentSessionId) else { return nil }
        let codexHome = codexHomeDirectory(environment: environment, fileManager: fileManager)
        let sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let standardizedWorkingDirectory = standardizedPath(workingDirectory)
        var selectedMatchingDirectory: (sessionId: String, createdAt: Date)?
        var selectedAnyDirectory: (sessionId: String, createdAt: Date)?

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false,
                  let meta = codexSessionMetaLine(fileURL: fileURL),
                  meta.type == nil || meta.type == "session_meta",
                  let payload = meta.payload,
                  normalized(payload.forkedFromId) == parentSessionId,
                  let sessionId = normalized(payload.id),
                  sessionId != parentSessionId else {
                continue
            }
            let createdAt = codexSessionCreatedAt(meta: meta) ?? values?.contentModificationDate ?? .distantPast
            if selectedAnyDirectory == nil || createdAt > selectedAnyDirectory!.createdAt {
                selectedAnyDirectory = (sessionId: sessionId, createdAt: createdAt)
            }
            guard let standardizedWorkingDirectory,
                  standardizedPath(payload.cwd) == standardizedWorkingDirectory else {
                continue
            }
            if selectedMatchingDirectory == nil || createdAt > selectedMatchingDirectory!.createdAt {
                selectedMatchingDirectory = (sessionId: sessionId, createdAt: createdAt)
            }
        }

        return (selectedMatchingDirectory ?? selectedAnyDirectory)?.sessionId
    }

    private static func codexHomeDirectory(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL {
        if let codexHome = normalized(environment["CODEX_HOME"]) {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func codexSessionMetaLine(fileURL: URL) -> CodexSessionMetaLine? {
        guard let firstLine = firstLineData(fileURL: fileURL) else { return nil }
        return try? JSONDecoder().decode(CodexSessionMetaLine.self, from: firstLine)
    }

    private static func codexSessionCreatedAt(meta: CodexSessionMetaLine) -> Date? {
        guard let timestamp = normalized(meta.timestamp) else { return nil }
        if let date = ISO8601DateFormatter().date(from: timestamp) {
            return date
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: timestamp)
    }

    private static func firstLineData(fileURL: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer {
            try? handle.close()
        }
        guard var data = try? handle.read(upToCount: codexSessionMetaReadLimit), !data.isEmpty else {
            return nil
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data[..<newline]
        }
        return data
    }

    private static func codexSessionCommand(in arguments: [String]) -> (name: String, sessionId: String)? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return nil
            }
            if !argument.hasPrefix("-") || argument == "-" {
                guard argument == "resume" || argument == "fork" else { return nil }
                return codexSessionIdValue(afterCommandAt: index, in: arguments).map {
                    (name: argument, sessionId: $0)
                }
            }
            let width = codexOptionWidth(arguments, index: index)
            if codexVariadicOptions.contains(argument) {
                let end = min(arguments.count, index + width)
                if index + 2 < end {
                    for candidateIndex in (index + 2)..<end
                    where arguments[candidateIndex] == "resume" || arguments[candidateIndex] == "fork" {
                        if let sessionId = codexSessionIdValue(afterCommandAt: candidateIndex, in: arguments) {
                            return (name: arguments[candidateIndex], sessionId: sessionId)
                        }
                    }
                }
            }
            index += width
        }
        return nil
    }

    private static func codexSessionIdValue(afterCommandAt commandIndex: Int, in arguments: [String]) -> String? {
        var index = commandIndex + 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return nil
            }
            if !argument.hasPrefix("-") || argument == "-" {
                guard codexLooksLikeSessionIdentifier(argument) else {
                    return nil
                }
                return normalized(argument)
            }
            let width = codexOptionWidth(arguments, index: index)
            if codexVariadicOptions.contains(argument) {
                let end = min(arguments.count, index + width)
                if index + 2 < end {
                    for candidateIndex in (index + 2)..<end {
                        if codexLooksLikeSessionIdentifier(arguments[candidateIndex]) {
                            return normalized(arguments[candidateIndex])
                        }
                    }
                }
            }
            index += width
        }
        return nil
    }

    private static func codexExecutablePath(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        if let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) {
            return launchExecutable
        }
        let argumentExecutable = observed.codexExecutableArgument
        if let argumentExecutable,
           argumentExecutable.contains("/") {
            return argumentExecutable
        }
        if let argumentExecutable,
           let resolved = executablePath(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           VaultObservedAgentProcess.argumentLooksLikeCodex(processPath) {
            return processPath
        }
        if let resolved = executablePath(named: "codex", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "codex"
    }

    private static func codexLaunchArguments(
        observed: VaultObservedAgentProcess,
        executablePath: String,
        tail: [String]? = nil
    ) -> [String]? {
        let tail = tail ?? codexLaunchTail(observed: observed)
        guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: tail) else {
            return nil
        }
        return [executablePath] + preserved
    }

    private static func codexLaunchCommand(
        observed: VaultObservedAgentProcess,
        executablePath: String,
        tail: [String],
        workingDirectory: String?
    ) -> AgentLaunchCommandSnapshot? {
        let environment = observed.environment
        let inheritedLauncher = normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        let inheritedArguments = decodeNULSeparatedBase64(environment["CMUX_AGENT_LAUNCH_ARGV_B64"])
        let canonicalInheritedLauncher = inheritedLauncher.flatMap(canonicalCodexInheritedLauncher)
        if inheritedLauncher != nil,
           canonicalInheritedLauncher == nil {
            return nil
        }
        if let canonicalInheritedLauncher,
           let inheritedArguments {
            guard let sanitizedArguments = AgentLaunchSanitizer.sanitizedLaunchArguments(
                inheritedArguments,
                launcher: canonicalInheritedLauncher,
                fallbackKind: "codex"
            ) else {
                return nil
            }
            let inheritedExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"])
                ?? inheritedArguments.first
                ?? executablePath
            let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
            return AgentLaunchCommandSnapshot(
                launcher: canonicalInheritedLauncher,
                executablePath: inheritedExecutable,
                arguments: sanitizedArguments,
                workingDirectory: workingDirectory,
                environment: selectedEnvironment.isEmpty ? nil : selectedEnvironment,
                capturedAt: nil,
                source: "environment"
            )
        }

        if let inheritedLauncher,
           !codexLaunchKindAllowsProcessFallback(inheritedLauncher) {
            return nil
        }
        guard let launchArguments = codexLaunchArguments(
            observed: observed,
            executablePath: executablePath,
            tail: tail
        ) else {
            return nil
        }
        return AgentLaunchCommandSnapshot(
            processDetectedLauncher: "codex",
            executablePath: executablePath,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    private static func codexLaunchTail(observed: VaultObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.codexExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        let processIdentityLooksLikeCodex = observed.executableBasenames.contains { basename in
            VaultObservedAgentProcess.argumentLooksLikeCodex(basename)
        }
        guard processIdentityLooksLikeCodex else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    private static let codexVariadicOptions: Set<String> = ["--image", "-i"]

    private static func codexOptionWidth(_ arguments: [String], index: Int) -> Int {
        guard index < arguments.count else { return 1 }
        let argument = arguments[index]
        if argument.contains("=") {
            return 1
        }
        let valueOptions: Set<String> = [
            "--config",
            "-c",
            "--remote",
            "--remote-auth-token-env",
            "--image",
            "-i",
            "--model",
            "-m",
            "--local-provider",
            "--profile",
            "-p",
            "--sandbox",
            "-s",
            "--ask-for-approval",
            "-a",
            "--cd",
            "-C",
            "--add-dir",
            "--enable",
            "--disable"
        ]
        guard valueOptions.contains(argument),
              index + 1 < arguments.count else {
            return 1
        }
        if codexVariadicOptions.contains(argument) {
            var end = index + 1
            while end < arguments.count, !arguments[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func codexLooksLikeSessionIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        if trimmed.hasPrefix("019") {
            return true
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) } && trimmed.contains("-")
    }

    private static func codexLaunchKindAllowsProcessFallback(_ launcher: String) -> Bool {
        switch normalizedLaunchKind(launcher) {
        case "", "codex":
            return true
        default:
            return false
        }
    }

    private static func canonicalCodexInheritedLauncher(_ launcher: String) -> String? {
        switch normalizedLaunchKind(launcher) {
        case "codex":
            return "codex"
        case "codexteams":
            return "codexTeams"
        default:
            return nil
        }
    }

    static func normalizedLaunchKind(_ launcher: String) -> String {
        launcher
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    static func decodeNULSeparatedBase64(_ rawValue: String?) -> [String]? {
        guard let rawValue = normalized(rawValue),
              let data = Data(base64Encoded: rawValue) else {
            return nil
        }
        var parts: [String] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0 {
                guard let value = String(data: data[start..<index], encoding: .utf8) else {
                    return nil
                }
                parts.append(value)
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            guard let value = String(data: data[start..<data.endIndex], encoding: .utf8) else {
                return nil
            }
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts
    }

    private static func processDetectedOpenCodeSnapshots(
        candidates: [RestorableAgentProcessDetectionCandidate],
        capturedAt: TimeInterval,
        fileManager: FileManager,
        latestOpenCodeSessionId: (String?, String?, FileManager) -> String?
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        var sessionByWorkingDirectoryAndParent: [String: String] = [:]
        var sessionMissesByWorkingDirectoryAndParent = Set<String>()
        var openCodeProcesses: [
            (
                panelKey: PanelKey,
                pid: Int,
                observed: VaultObservedAgentProcess,
                environment: [String: String],
                workingDirectory: String?,
                workingDirectoryKey: String,
                source: RestorableAgentProcessDetectionCandidateSource,
                isForeground: Bool,
                matchesFallbackScope: Bool
            )
        ] = []
        var selectedCandidateByPanelKey: [
            PanelKey: (source: RestorableAgentProcessDetectionCandidateSource, isForeground: Bool, matchesFallbackScope: Bool)
        ] = [:]

        for candidate in candidates {
            let process = candidate.process
            let processArguments = candidate.arguments
            guard process.canBeActiveAgentProcess else { continue }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isOpenCodeProcess else { continue }

            let cwd = openCodeWorkingDirectory(observed: observed)
            let cwdKey = cwd.map { ($0 as NSString).standardizingPath } ?? ""
            let panelKey = candidate.panelKey
            openCodeProcesses.append((
                panelKey: panelKey,
                pid: process.pid,
                observed: observed,
                environment: processArguments.environment,
                workingDirectory: cwd,
                workingDirectoryKey: cwdKey,
                source: candidate.source,
                isForeground: process.isForegroundProcess,
                matchesFallbackScope: candidate.matchesFallbackScope
            ))
        }

        let fallbackRemappedPIDs = Set(openCodeProcesses.filter { $0.source == .fallbackScope }.map(\.pid))
        var panelKeysByWorkingDirectory: [String: Set<PanelKey>] = [:]
        for process in openCodeProcesses {
            if process.source == .cmuxScoped,
               fallbackRemappedPIDs.contains(process.pid) {
                continue
            }
            panelKeysByWorkingDirectory[process.workingDirectoryKey, default: []].insert(process.panelKey)
        }

        for process in openCodeProcesses {
            let sameWorkingDirectoryPanelCount = panelKeysByWorkingDirectory[process.workingDirectoryKey]?.count ?? 0
            let hasForkFlag = process.observed.arguments.hasOpenCodeForkFlag
            let forkParentSessionId = process.observed.arguments.openCodeForkParentSessionId
                ?? (hasForkFlag ? process.observed.arguments.value(afterOption: "--session") : nil)
            let latestSessionId: String?
            let sessionCacheKey = process.workingDirectoryKey + "\u{1f}" + (forkParentSessionId ?? "")
            if !hasForkFlag || forkParentSessionId == nil || sameWorkingDirectoryPanelCount != 1 || process.workingDirectory == nil {
                latestSessionId = nil
            } else if let cached = sessionByWorkingDirectoryAndParent[sessionCacheKey] {
                latestSessionId = cached
            } else if sessionMissesByWorkingDirectoryAndParent.contains(sessionCacheKey) {
                latestSessionId = nil
            } else {
                latestSessionId = latestOpenCodeSessionId(process.workingDirectory, forkParentSessionId, fileManager)
                if let latestSessionId {
                    sessionByWorkingDirectoryAndParent[sessionCacheKey] = latestSessionId
                } else {
                    sessionMissesByWorkingDirectoryAndParent.insert(sessionCacheKey)
                }
            }
            guard let sessionId = openCodeFallbackSessionIdForProcess(
                arguments: process.observed.arguments,
                latestSessionIdForSolePanel: latestSessionId,
                sameWorkingDirectoryPanelCount: sameWorkingDirectoryPanelCount
            ) else { continue }

            let executablePath = openCodeExecutablePath(
                observed: process.observed,
                environment: process.environment
            )
            guard let launchArguments = openCodeLaunchArguments(
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
            if let existing = selectedCandidateByPanelKey[process.panelKey] {
                if !processDetectionShouldReplaceCandidate(
                    existing: existing,
                    candidate: (
                        source: process.source,
                        isForeground: process.isForeground,
                        matchesFallbackScope: process.matchesFallbackScope
                    )
                ) {
                    continue
                }
            }
            resolved[process.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt
            )
            selectedCandidateByPanelKey[process.panelKey] = (
                source: process.source,
                isForeground: process.isForeground,
                matchesFallbackScope: process.matchesFallbackScope
            )
        }

        return resolved
    }

    private static func openCodeExecutablePath(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        let argumentExecutable = observed.openCodeExecutableArgument
        if let argumentExecutable,
           argumentExecutable.contains("/") {
            return argumentExecutable
        }
        if let argumentExecutable,
           let resolved = executablePath(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           VaultObservedAgentProcess.argumentLooksLikeOpenCode(processPath) {
            return processPath
        }
        if let resolved = executablePath(named: "opencode", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "opencode"
    }

    private static func openCodeLaunchArguments(
        observed: VaultObservedAgentProcess,
        executablePath: String
    ) -> [String]? {
        let tail = openCodeLaunchTail(observed: observed)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: tail) else {
            return nil
        }
        return [executablePath] + preserved
    }

    private static func openCodeLaunchTail(observed: VaultObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.openCodeExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        let processIdentityLooksLikeOpenCode = observed.executableBasenames.contains { basename in
            VaultObservedAgentProcess.argumentLooksLikeOpenCode(basename)
        }
        guard processIdentityLooksLikeOpenCode else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    private static func openCodeWorkingDirectory(observed: VaultObservedAgentProcess) -> String? {
        let fallbackWorkingDirectory = normalized(
            observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
        )
        return openCodeProjectWorkingDirectory(
            observed: observed,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        ) ?? fallbackWorkingDirectory
    }

    private static func openCodeProjectWorkingDirectory(
        observed: VaultObservedAgentProcess,
        fallbackWorkingDirectory: String?
    ) -> String? {
        guard let project = openCodeProjectArgument(in: openCodeLaunchTail(observed: observed)) else {
            return nil
        }
        return resolvedOpenCodeProjectPath(project, fallbackWorkingDirectory: fallbackWorkingDirectory)
    }

    private static func openCodeProjectArgument(in arguments: [String]) -> String? {
        let commandNames: Set<String> = [
            "completion",
            "acp",
            "mcp",
            "attach",
            "run",
            "debug",
            "providers",
            "auth",
            "agent",
            "upgrade",
            "uninstall",
            "serve",
            "web",
            "models",
            "stats",
            "export",
            "import",
            "github",
            "pr",
            "session",
            "plugin",
            "plug",
            "db"
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? arguments[nextIndex] : nil
            }
            if argument.hasPrefix("-") {
                index += openCodeOptionWidth(arguments, index: index)
                continue
            }
            return commandNames.contains(argument) ? nil : argument
        }
        return nil
    }

    private static func openCodeOptionWidth(_ arguments: [String], index: Int) -> Int {
        guard index < arguments.count else { return 1 }
        let argument = arguments[index]
        if argument.contains("=") {
            return 1
        }
        let valueOptions: Set<String> = [
            "--log-level",
            "--port",
            "--hostname",
            "--mdns-domain",
            "--cors",
            "--model",
            "-m",
            "--session",
            "-s",
            "--prompt",
            "--agent"
        ]
        guard valueOptions.contains(argument),
              index + 1 < arguments.count else {
            return 1
        }
        if argument == "--cors" {
            var end = index + 1
            while end < arguments.count, !arguments[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func resolvedOpenCodeProjectPath(
        _ rawValue: String,
        fallbackWorkingDirectory: String?
    ) -> String? {
        guard let project = normalized(rawValue) else { return nil }
        let expandedProject = (project as NSString).expandingTildeInPath
        if expandedProject.hasPrefix("/") {
            return (expandedProject as NSString).standardizingPath
        }
        guard let fallbackWorkingDirectory = normalized(fallbackWorkingDirectory) else {
            return (expandedProject as NSString).standardizingPath
        }
        return URL(fileURLWithPath: fallbackWorkingDirectory, isDirectory: true)
            .appendingPathComponent(expandedProject)
            .standardizedFileURL
            .path
    }

    static func executablePath(
        named name: String,
        environment: [String: String]
    ) -> String? {
        let executableName = (name as NSString).lastPathComponent
        guard !executableName.isEmpty else { return nil }
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(path), isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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

    static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func standardizedPath(_ rawValue: String?) -> String? {
        normalized(rawValue).map { ($0 as NSString).standardizingPath }
    }
}

struct VaultObservedAgentProcess: Sendable {
    let processName: String
    let processPath: String?
    let arguments: [String]
    let environment: [String: String]

    var executableBasenames: [String] {
        var names: [String] = []
        if !processName.isEmpty { names.append(processName) }
        if let processPath, !processPath.isEmpty { names.append((processPath as NSString).lastPathComponent) }
        if let first = arguments.first, !first.isEmpty { names.append((first as NSString).lastPathComponent) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    var isOpenCodeProcess: Bool {
        processIdentityLooksLikeOpenCode || openCodeExecutableArgumentIndex != nil
    }

    var isCodexProcess: Bool {
        processIdentityLooksLikeCodex || codexExecutableArgumentIndex != nil
    }

    var openCodeExecutableArgument: String? {
        guard let index = openCodeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    var openCodeExecutableArgumentIndex: Int? {
        if let first = arguments.first,
           Self.argumentLooksLikeOpenCode(first) {
            return 0
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return nil
        }
        guard let scriptIndex = Self.nodeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeOpenCode(arguments[scriptIndex]) ? scriptIndex : nil
    }

    var codexExecutableArgument: String? {
        guard let index = codexExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    var codexExecutableArgumentIndex: Int? {
        if let first = arguments.first,
           Self.argumentLooksLikeCodex(first) {
            return 0
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return nil
        }
        guard let scriptIndex = Self.nodeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeCodex(arguments[scriptIndex]) ? scriptIndex : nil
    }

    private var processIdentityLooksLikeOpenCode: Bool {
        executableBasenames.contains { basename in
            let normalized = basename.lowercased()
            return normalized == "opencode" ||
                normalized == ".opencode" ||
                normalized == "opencode-ai" ||
                normalized == "open-code"
        }
    }

    static func argumentLooksLikeOpenCode(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "opencode" ||
            basename == ".opencode" ||
            basename == "opencode-ai" ||
            basename == "open-code"
    }

    private var processIdentityLooksLikeCodex: Bool {
        executableBasenames.contains { basename in
            Self.argumentLooksLikeCodex(basename)
        }
    }

    static func argumentLooksLikeCodex(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
            .replacingOccurrences(of: "\\", with: "/")
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "codex" ||
            normalized.contains("/@openai/codex/")
    }

    static func wrapperLooksLikeNodeRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node":
            return true
        default:
            return false
        }
    }

    static func nodeScriptArgumentIndex(_ arguments: [String]) -> Int? {
        guard !arguments.isEmpty else { return nil }
        var index = 0
        if wrapperLooksLikeNodeRuntime((arguments[0] as NSString).lastPathComponent) {
            index = 1
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? nextIndex : nil
            }
            if argument.hasPrefix("-") {
                if nodeOptionConsumesScript(argument) {
                    return nil
                }
                index += 1 + nodeOptionValueCount(argument)
                continue
            }
            return index
        }
        return nil
    }

    private static func nodeOptionConsumesScript(_ argument: String) -> Bool {
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        switch option {
        case "-e", "--eval", "-p", "--print", "-c", "--check":
            return true
        default:
            return false
        }
    }

    private static func nodeOptionValueCount(_ argument: String) -> Int {
        if argument.contains("=") {
            return 0
        }
        switch argument {
        case "-r", "--require", "--import", "--loader", "--experimental-loader",
             "--conditions", "-C", "--title", "--test-name-pattern",
             "--test-reporter", "--test-reporter-destination":
            return 1
        default:
            return 0
        }
    }
}

private extension CmuxVaultAgentDetectRule {
    func matches(_ process: VaultObservedAgentProcess) -> Bool {
        guard processName != nil || !argvContains.isEmpty else { return false }
        let processNameMatch = processName.map { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        } ?? true
        let argvContainsMatch = argvContains.isEmpty || argvContains.allSatisfy { needle in
            if needle.contains(" ") {
                let joinedArguments = process.arguments.joined(separator: " ")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            if needle.contains("/") {
                let joinedArguments = process.arguments.joined(separator: "\u{0}")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            return process.arguments.contains { argument in
                argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                    || (argument as NSString).lastPathComponent.range(
                        of: needle,
                        options: [.caseInsensitive, .literal]
                    ) != nil
            }
        }
        return processNameMatch && argvContainsMatch
    }
}

private extension CmuxVaultAgentSessionIDSource {
    func sessionId(
        from process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> String? {
        switch self {
        case .argvOption(let option):
            return process.arguments.value(afterOption: option)
        case .piSessionFile:
            if let session = process.arguments.value(afterOption: "--session") {
                return PiSessionLocator.resolvedSessionPath(
                    session,
                    for: process,
                    registration: registration,
                    fileManager: fileManager
                ) ?? session
            }
            return PiSessionLocator.latestSessionPath(for: process, registration: registration, fileManager: fileManager)
        }
    }
}

extension Array where Element == String {
    var hasOpenCodeForkFlag: Bool {
        contains { $0 == "--fork" || $0.hasPrefix("--fork=") }
    }

    var openCodeForkParentSessionId: String? {
        for argument in self {
            let prefix = "--fork="
            guard argument.hasPrefix(prefix) else { continue }
            let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    func value(afterOption option: String) -> String? {
        for index in indices {
            let argument = self[index]
            if argument == option {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { return nil }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

enum PiSessionLocator {
    static func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return (standardizedHome as NSString).appendingPathComponent(".pi/agent/sessions")
    }

    static func projectDirectoryName(for workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutLeadingSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let sanitized = withoutLeadingSlash
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }
        return "--\(sanitized)--"
    }

    fileprivate static func latestSessionPath(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> String? {
        newestJSONLFile(in: candidateSessionDirectory(for: process, registration: registration), fileManager: fileManager)?.path
    }

    fileprivate static func resolvedSessionPath(
        _ session: String,
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> String? {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.fileExists(atPath: expanded) ? expanded : trimmed
        }

        let directory = candidateSessionDirectory(for: process, registration: registration)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: directory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.deletingPathExtension().lastPathComponent.contains(trimmed) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url.path
    }

    private static func candidateSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String {
        let sessionRoot = process.arguments.value(afterOption: "--session-dir")
            ?? process.environment["PI_CODING_AGENT_SESSION_DIR"]
            ?? registration.sessionDirectory
            ?? defaultSessionsRoot()
        let expandedRoot = (sessionRoot as NSString).expandingTildeInPath
        if let cwd = process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"],
           let projectDirectory = projectDirectoryName(for: cwd) {
            return (expandedRoot as NSString).appendingPathComponent(projectDirectory)
        }
        return expandedRoot
    }

    static func newestJSONLFile(in directory: String, fileManager: FileManager = .default) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: directory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }
}
