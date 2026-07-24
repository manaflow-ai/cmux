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
        var selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment, kind: launcher)
        if ["opencode", "pi", "omp"].contains(launcher),
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
        capturedAt: TimeInterval,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        // KERN_PROCARGS2 argv/env decoding is the expensive unit of this scan; memoize so
        // the OpenCode, fork-parent-fallback, and registry passes read each pid once.
        // updateValue (not subscript) so a nil miss is unambiguously stored, not removed.
        var processArgumentsByPID: [Int: CmuxTopProcessArguments?] = [:]
        func cachedProcessArguments(_ processID: Int) -> CmuxTopProcessArguments? {
            if let cached = processArgumentsByPID[processID] { return cached }
            let resolved = processArgumentsProvider(processID)
            processArgumentsByPID.updateValue(resolved, forKey: processID)
            return resolved
        }

        let scopedProcessIDsByPanelKey = processSnapshot.cmuxScopedProcessIDsByPanelKey()
        var resolved = processDetectedOpenCodeSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey,
            processArgumentsProvider: cachedProcessArguments
        )
        resolved.merge(processDetectedOllamaSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey,
            processArgumentsProvider: cachedProcessArguments
        )) { existing, _ in existing }
        resolved.merge(processDetectedForkParentFallbackSnapshots(processSnapshot: processSnapshot, capturedAt: capturedAt, scopedProcessIDsByPanelKey: scopedProcessIDsByPanelKey, processArgumentsProvider: cachedProcessArguments)) { existing, _ in existing }
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
                  registration.processDetectedSnapshotIsRestorable(for: observed),
                  let sessionIDResolution = registration.sessionIdSource.sessionIDResolution(
                      from: observed,
                      registration: registration,
                      fileManager: fileManager
                  ) else {
                continue
            }
            let sessionId = sessionIDResolution.sessionId

            let useDefaultExecutable = registration.detect.usesAlternateMatchWithoutPrimaryMatch(observed)
            var executablePath = useDefaultExecutable
                ? registration.defaultExecutable
                : (normalized(observed.arguments.first) ?? normalized(process.path) ?? registration.defaultExecutable)
            var arguments = useDefaultExecutable
                ? registration.detect.alternateLaunchArguments(for: observed, defaultExecutable: executablePath)
                : (observed.arguments.isEmpty ? [executablePath] : observed.arguments)
            if registration.id == CmuxVaultAgentRegistration.builtInCampfire.id {
                arguments = CampfireLaunchArgumentNormalizer(
                    defaultExecutable: registration.defaultExecutable
                ).normalized(arguments: observed.arguments)
                executablePath = arguments.first ?? registration.defaultExecutable
            }
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

    private static func processDetectedOpenCodeSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]
        var sessionByWorkingDirectoryAndParent: [String: String] = [:]
        var sessionMissesByWorkingDirectoryAndParent = Set<String>()
        var openCodeProcesses: [
            (
                panelKey: PanelKey,
                processID: Int,
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
                  let processArguments = processArgumentsProvider(process.pid) else {
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
                processID: process.pid,
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
                agentProcessIDs: [process.processID],
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
            return VaultAgentSessionIDResolution(sessionId: sessionId, source: registration.processArgumentsCarryForkParentFlag(process.arguments) ? .forkParentFallback : .explicit)
        case .piSessionFile:
            let carriesForkParentFlag = registration.processArgumentsCarryForkParentFlag(process.arguments)
            if let session = process.piCompatibleSessionID {
                let sessionId = PiSessionLocator.resolvedSessionPath(
                    session,
                    for: process,
                    registration: registration,
                    fileManager: fileManager
                ) ?? session
                return VaultAgentSessionIDResolution(
                    sessionId: sessionId,
                    source: carriesForkParentFlag ? .forkParentFallback : .explicit
                )
            }
            if carriesForkParentFlag {
                return nil
            }
            guard let sessionId = PiSessionLocator.latestSessionPath(
                for: process,
                registration: registration,
                fileManager: fileManager
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
        var result: [RestorableAgentSessionIndex.PanelKey: Set<Int>] = [:]
        for process in cmuxScopedProcesses() {
            if let workspaceId = process.cmuxWorkspaceID, let panelId = process.cmuxSurfaceID {
                result[.init(workspaceId: workspaceId, panelId: panelId), default: []].insert(process.pid)
            }
        }
        return result
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

    var piCompatibleForkParentSessionID: String? {
        nonOptionValue(afterOption: "--fork")
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

}
