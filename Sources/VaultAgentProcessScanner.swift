import Foundation
import CMUXAgentLaunch
import SQLite3

extension AgentLaunchCommandSnapshot {
    init(
        processDetectedLauncher launcher: String,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) {
        var selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment, kind: launcher)
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
        switch kind {
        case .claude:
            return sessionIdAfterOption(
                arguments,
                options: ["--resume", "-r", "--session-id"],
                valuePrefixes: ["--resume=", "--session-id="]
            )
        case .codex:
            if let id = sessionIdAfterOption(arguments, options: ["--resume", "-r"], valuePrefixes: ["--resume="]) {
                return id
            }
            if let index = arguments.firstIndex(of: "resume"),
               index + 1 < arguments.endIndex,
               !arguments[index + 1].hasPrefix("-") {
                return normalized(arguments[index + 1])
            }
            return nil
        default:
            return nil
        }
    }

    private static func sessionIdAfterOption(
        _ arguments: [String],
        options: Set<String>,
        valuePrefixes: [String]
    ) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if options.contains(argument),
               index + 1 < arguments.endIndex,
               !arguments[index + 1].hasPrefix("-") {
                return normalized(arguments[index + 1])
            }
            for prefix in valuePrefixes where argument.hasPrefix(prefix) {
                return normalized(String(argument.dropFirst(prefix.count)))
            }
            index += 1
        }
        return nil
    }

    private static func processDetectedOpenCodeSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>]
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
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

            let cwd = openCodeWorkingDirectory(observed: observed)
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
            resolved[process.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[process.panelKey] ?? [],
                sessionIDSource: .explicit
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

    private static func executablePath(
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

private struct VaultObservedAgentProcess: Sendable {
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

    /// True for a real `claude` process: the binary basename is `claude`
    /// (`~/.local/bin/claude` symlink), or a node/bun runtime running claude
    /// (`node …/.claude/cli.js`, `…/claude/versions/…`). Mirrors the live-PID
    /// matcher `liveProcessExecutableMatchesRecordedAgent`. A `sr claude` / shell
    /// wrapper has argv[0] basename `sr`/`sh` and is excluded.
    var isClaudeProcess: Bool {
        if executableBasenames.contains(where: { $0.lowercased() == "claude" }) {
            return true
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return false
        }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return (argument as NSString).lastPathComponent.lowercased() == "claude"
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    /// True for a real `codex` process: the binary basename is `codex` (the
    /// vendored `…/@openai/codex-darwin-arm64/…/bin/codex`), or a runtime arg
    /// references the codex npm package. A `sr codex` wrapper has argv[0]
    /// basename `sr` and is excluded.
    var isCodexProcess: Bool {
        if executableBasenames.contains(where: { $0.lowercased() == "codex" }) {
            return true
        }
        return arguments.contains { argument in
            let lowered = argument.lowercased()
            return lowered.contains("@openai/codex") || lowered.contains("codex-darwin-arm64")
        }
    }

    var openCodeExecutableArgument: String? {
        guard let index = openCodeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    var piCompatibleSessionID: String? {
        arguments.piCompatibleSessionID(startingAt: piCompatibleSessionArgumentStartIndex)
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

    private var piCompatibleSessionArgumentStartIndex: Int {
        guard !arguments.isEmpty else { return 0 }
        if let scriptIndex = Self.javaScriptRuntimeScriptArgumentIndex(arguments) {
            return min(scriptIndex + 1, arguments.endIndex)
        }
        if arguments[arguments.startIndex].hasPrefix("-") {
            return arguments.startIndex
        }
        return min(arguments.startIndex + 1, arguments.endIndex)
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

    static func argumentLooksLikeTmux(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmux(argument)
    }

    static func argumentLooksLikeTmuxProcessTitle(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmuxProcessTitle(argument)
    }

    static func argumentLooksLikeTmuxServerProcessTitle(_ argument: String) -> Bool {
        TmuxResumeParser.argumentLooksLikeTmuxServerProcessTitle(argument)
    }

    private static func wrapperLooksLikeJavaScriptRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node", "bun", "deno", "tsx", "ts-node":
            return true
        default:
            return false
        }
    }

    private static func wrapperLooksLikeNodeRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node":
            return true
        default:
            return false
        }
    }

    private static func javaScriptRuntimeScriptArgumentIndex(_ arguments: [String]) -> Int? {
        guard let first = arguments.first else { return nil }
        guard wrapperLooksLikeJavaScriptRuntime((first as NSString).lastPathComponent) else {
            return nil
        }
        var index = 1
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

    private static func nodeScriptArgumentIndex(_ arguments: [String]) -> Int? {
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
        var expectedNames = processNames
        if let processName {
            expectedNames.append(processName)
        }
        guard !expectedNames.isEmpty || !argvContains.isEmpty || !alternateArgvContains.isEmpty else {
            return false
        }
        let processNameMatch = expectedNames.isEmpty || expectedNames.contains { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
        let argvContainsMatch = argvContains.isEmpty || process.argumentsContainAll(argvContains)
        let alternateArgvContainsMatch = !alternateArgvContains.isEmpty
            && process.argumentsContainAll(alternateArgvContains)
        return (processNameMatch && argvContainsMatch) || alternateArgvContainsMatch
    }
}

private extension VaultObservedAgentProcess {
    func argumentsContainAll(_ needles: [String]) -> Bool {
        needles.allSatisfy { needle in
            if needle.contains(" ") {
                let joinedArguments = arguments.joined(separator: " ")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            if needle.contains("/") {
                let joinedArguments = arguments.joined(separator: "\u{0}")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            return arguments.contains { argument in
                argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                    || (argument as NSString).lastPathComponent.range(
                        of: needle,
                        options: [.caseInsensitive, .literal]
                    ) != nil
            }
        }
    }
}

private struct VaultAgentSessionIDResolution {
    let sessionId: String
    let source: RestorableAgentSessionIndex.ProcessDetectedSessionIDSource
}

private extension CmuxVaultAgentSessionIDSource {
    func sessionIDResolution(
        from process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> VaultAgentSessionIDResolution? {
        switch self {
        case .argvOption(let option):
            guard let sessionId = process.arguments.nonOptionValue(afterOption: option) else { return nil }
            return VaultAgentSessionIDResolution(sessionId: sessionId, source: .explicit)
        case .piSessionFile:
            let locator = PiSessionLocator(fileManager: fileManager)
            if let session = process.piCompatibleSessionID {
                let sessionId = locator.resolvedSessionPath(
                    session,
                    for: process,
                    registration: registration
                ) ?? session
                return VaultAgentSessionIDResolution(sessionId: sessionId, source: .explicit)
            }
            guard let sessionId = locator.latestSessionPath(
                for: process,
                registration: registration
            ) else {
                return nil
            }
            return VaultAgentSessionIDResolution(sessionId: sessionId, source: .inferredLatestSessionFile)
        case .grokSessionDirectory:
            if let session = process.arguments.grokResumeSessionID {
                return VaultAgentSessionIDResolution(sessionId: session, source: .explicit)
            }
            return nil
        }
    }
}

private extension CmuxTopProcessSnapshot {
    func cmuxScopedProcessIDsByPanelKey() -> [RestorableAgentSessionIndex.PanelKey: Set<Int>] {
        var processIDsByPanelKey: [RestorableAgentSessionIndex.PanelKey: Set<Int>] = [:]
        for process in cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID else {
                continue
            }
            let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            processIDsByPanelKey[key, default: []].insert(process.pid)
        }
        return processIDsByPanelKey
    }
}

private extension Array where Element == String {
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

    func nonOptionValue(afterOption option: String) -> String? {
        guard let value = value(afterOption: option), !value.hasPrefix("-") else {
            return nil
        }
        return value
    }

    func piCompatibleSessionID(startingAt startIndex: Int) -> String? {
        guard startIndex < endIndex else { return nil }
        for index in indices where index >= startIndex {
            let argument = self[index]
            if argument == "--session" || argument == "--resume" || argument == "-r" {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { continue }
                if let value = normalizedNonOptionValue(self[nextIndex]) {
                    return value
                }
                continue
            }
            if argument.hasPrefix("--session="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--session=".count))) {
                return value
            }
            if argument.hasPrefix("--resume="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--resume=".count))) {
                return value
            }
            if argument.hasPrefix("-r="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("-r=".count))) {
                return value
            }
        }
        return nil
    }

    private func normalizedNonOptionValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.hasPrefix("-") ? value : nil
    }

    var grokResumeSessionID: String? {
        let options = ["-r", "--resume"]
        for index in indices {
            let argument = self[index]
            if options.contains(argument) {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { continue }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
                continue
            }
            for option in options {
                let prefix = option + "="
                guard argument.hasPrefix(prefix) else { continue }
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
            }
        }
        return nil
    }
}

struct PiSessionLocator: Sendable {
    // `FileManager` is not `Sendable`, but `FileManager.default` is documented as
    // thread-safe and the only value injected here; `nonisolated(unsafe) let` is the
    // sanctioned escape hatch for an immutable, effectively-Sendable stored property.
    nonisolated(unsafe) let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

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

    func latestSessionPath(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        newestJSONLFile(in: Self.candidateSessionDirectory(for: process, registration: registration))?.path
    }

    func resolvedSessionPath(
        _ session: String,
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.fileExists(atPath: expanded) ? expanded : trimmed
        }

        let directory = Self.candidateSessionDirectory(for: process, registration: registration)
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

        var exactNewest: (url: URL, modified: Date)?
        var partialNewest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let basename = url.deletingPathExtension().lastPathComponent
            guard basename == trimmed || basename.contains(trimmed) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if basename == trimmed {
                if exactNewest == nil || modified > exactNewest!.modified {
                    exactNewest = (url, modified)
                }
            } else if partialNewest == nil || modified > partialNewest!.modified {
                partialNewest = (url, modified)
            }
        }
        return exactNewest?.url.path ?? partialNewest?.url.path
    }

    private static func candidateSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String {
        let sessionRoot = process.arguments.value(afterOption: "--session-dir")
            ?? process.environment["PI_CODING_AGENT_SESSION_DIR"]
            ?? configuredSessionDirectory(for: registration)
            ?? ompAgentSessionsRoot(for: process, registration: registration)
            ?? registration.sessionDirectory
            ?? defaultSessionsRoot()
        let expandedRoot = (sessionRoot as NSString).expandingTildeInPath
        if let cwd = process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"],
           let projectDirectory = projectDirectoryName(for: cwd) {
            return (expandedRoot as NSString).appendingPathComponent(projectDirectory)
        }
        return expandedRoot
    }

    private static func ompAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard registration.id == "omp" else { return nil }
        if let agentRoot = nonEmptyEnvironmentValue("PI_CODING_AGENT_DIR", in: process.environment) {
            let expandedAgentRoot = NSString(string: agentRoot).expandingTildeInPath
            return (expandedAgentRoot as NSString).appendingPathComponent("sessions")
        }
        guard let configDir = nonEmptyEnvironmentValue("PI_CONFIG_DIR", in: process.environment) else {
            return nil
        }
        let home = nonEmptyEnvironmentValue("HOME", in: process.environment) ?? NSHomeDirectory()
        let expandedConfigDir = NSString(string: configDir).expandingTildeInPath
        let configRoot: String
        if (expandedConfigDir as NSString).isAbsolutePath {
            configRoot = expandedConfigDir
        } else {
            configRoot = ((NSString(string: home).expandingTildeInPath) as NSString)
                .appendingPathComponent(configDir)
        }
        let agentRoot = (configRoot as NSString).appendingPathComponent("agent")
        return (agentRoot as NSString).appendingPathComponent("sessions")
    }

    private static func configuredSessionDirectory(for registration: CmuxVaultAgentRegistration) -> String? {
        guard let sessionDirectory = registration.sessionDirectory else { return nil }
        if registration.id == "omp",
           sessionDirectory == CmuxVaultAgentRegistration.builtInOmp.sessionDirectory {
            return nil
        }
        return sessionDirectory
    }

    private static func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func newestJSONLFile(in directory: String) -> URL? {
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
