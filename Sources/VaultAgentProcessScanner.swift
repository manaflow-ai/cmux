import Foundation
import CMUXAgentLaunch
import SQLite3

/// Tracks fingerprint of latest assistant message per (workspace, panel, session)
/// to emit completion notifications only on change, not on first observation.
private actor OpenCodeCompletionTracker {
    // Key: "workspaceId:panelId:sessionId"
    private var fingerprintsByKey: [String: (timeCreated: Int64, dataLength: Int)] = [:]
    private var isPolling = false

    func beginPolling() -> Bool {
        guard !isPolling else { return false }
        isPolling = true
        return true
    }

    func endPolling() {
        isPolling = false
    }

    func updateFingerprint(
        _ fingerprint: (timeCreated: Int64, dataLength: Int),
        for key: String
    ) -> Bool {
        if let existing = fingerprintsByKey[key] {
            let changed = existing.timeCreated != fingerprint.timeCreated
                || existing.dataLength != fingerprint.dataLength
            fingerprintsByKey[key] = fingerprint
            return changed
        }

        fingerprintsByKey[key] = fingerprint
        return false
    }
}

private let openCodeCompletionTracker = OpenCodeCompletionTracker()

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
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval, processIDs: Set<Int>)] {
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
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval, processIDs: Set<Int>)] {
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
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        let openCodeResult = processDetectedOpenCodeSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager
        )
        var resolved = openCodeResult.resolved

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
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            resolved[key] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: processSnapshot.cmuxScopedProcessIDs(for: key)
            )
        }

        return resolved
    }

    static func pollOpenCodeCompletionNotifications(
        currentSocketPath: String? = nil,
        fileManager: FileManager = .default
    ) async {
        guard await openCodeCompletionTracker.beginPolling() else { return }

        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        let openCodeResult = processDetectedOpenCodeSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager,
            currentSocketPath: currentSocketPath
        )
        await processOpenCodeCompletionNotifications(
            resolved: openCodeResult.resolved,
            perPanelDBURLs: openCodeResult.perPanelDBURLs,
            fileManager: fileManager
        )
        await openCodeCompletionTracker.endPolling()
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
        currentSocketPath: String? = nil
    ) -> (
        resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)],
        perPanelDBURLs: [PanelKey: URL]
    ) {
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        var perPanelDBURLs: [PanelKey: URL] = [:]
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
            if let currentSocketPath {
                guard let processSocketPath = processArguments.environment["CMUX_SOCKET_PATH"],
                      !processSocketPath.isEmpty,
                      SocketControlSettings.pathsMatch(processSocketPath, currentSocketPath) else {
                    continue
                }
            }

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

            // Resolve per-panel MMS DB URL before session guard so it can serve as fallback.
            let perPanelDBURL = openCodeDatabaseURL(
                environment: process.environment,
                fileManager: fileManager
            )
            if let perPanelDBURL {
                perPanelDBURLs[process.panelKey] = perPanelDBURL
            }

            let sessionId: String?
            if let fallbackSessionId = openCodeFallbackSessionIdForProcess(
                arguments: process.observed.arguments,
                latestSessionIdForSolePanel: latestSessionId,
                sameWorkingDirectoryPanelCount: sameWorkingDirectoryPanelCount
            ) {
                sessionId = fallbackSessionId
            } else if let perPanelDBURL {
                sessionId = latestOpenCodeSessionId(
                    sourcePath: perPanelDBURL.path,
                    workingDirectory: process.workingDirectory
                )
            } else {
                sessionId = nil
            }
            guard let sessionId else { continue }

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
                processIDs: processSnapshot.cmuxScopedProcessIDs(for: process.panelKey)
            )
        }

        return (resolved: resolved, perPanelDBURLs: perPanelDBURLs)
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

    private static func openCodeDatabaseURL(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        guard let mmsSessionHome = environment["MMS_SESSION_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mmsSessionHome.isEmpty else {
            return nil
        }
        let dbPath = (mmsSessionHome as NSString).appendingPathComponent(".local/share/opencode/opencode.db")
        guard fileManager.fileExists(atPath: dbPath) else { return nil }
        return URL(fileURLWithPath: dbPath)
    }

    private static func latestOpenCodeSessionId(
        sourcePath: String,
        workingDirectory: String?
    ) -> String? {
        let snapshot: OpenCodeDatabaseSnapshot.Snapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(
                from: sourcePath,
                prefix: "cmux-opencode-mms"
            ) else {
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

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

        // Prefer exact working directory match.
        if let cwd = normalized(workingDirectory).map({ ($0 as NSString).standardizingPath }) {
            let exactSQL = """
                SELECT id FROM session
                WHERE directory = ?
                ORDER BY time_updated DESC
                LIMIT 1
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, exactSQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, cwd, -1, SQLITE_TRANSIENT_FN)
                if sqlite3_step(stmt) == SQLITE_ROW,
                   let sessionId = SessionIndexStore.sqliteText(stmt, 0),
                   !sessionId.isEmpty {
                    return sessionId
                }
            }
        }

        // Fallback to latest session in this per-panel DB.
        let fallbackSQL = """
            SELECT id FROM session
            ORDER BY time_updated DESC
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let sessionId = SessionIndexStore.sqliteText(stmt, 0),
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }

    // MARK: - OpenCode completion notification

    private static func processOpenCodeCompletionNotifications(
        resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)],
        perPanelDBURLs: [PanelKey: URL],
        fileManager: FileManager
    ) async {
        _ = fileManager
        guard !resolved.isEmpty else { return }

        var panelsBySourcePath: [String?: [(PanelKey, SessionRestorableAgentSnapshot)]] = [:]
        for (panelKey, pair) in resolved {
            guard pair.snapshot.kind == .opencode, !pair.snapshot.sessionId.isEmpty else { continue }
            let sourcePath = perPanelDBURLs[panelKey]?.path
            panelsBySourcePath[sourcePath, default: []].append((panelKey, pair.snapshot))
        }
        guard !panelsBySourcePath.isEmpty else { return }

        for (sourcePath, panels) in panelsBySourcePath {
            let snapshot: OpenCodeDatabaseSnapshot.Snapshot
            do {
                let made: OpenCodeDatabaseSnapshot.Snapshot?
                if let sourcePath {
                    made = try OpenCodeDatabaseSnapshot.make(from: sourcePath, prefix: "cmux-opencode-notify")
                } else {
                    made = try OpenCodeDatabaseSnapshot.make(prefix: "cmux-opencode-notify")
                }
                guard let made else { continue }
                snapshot = made
            } catch {
                continue
            }
            defer { snapshot.remove() }

            var db: OpaquePointer?
            guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }

            for (panelKey, panelSnapshot) in panels {
                await processOpenCodePanelCompletion(db: db, panelKey: panelKey, snapshot: panelSnapshot)
            }
        }
    }

    private static func processOpenCodePanelCompletion(
        db: OpaquePointer,
        panelKey: PanelKey,
        snapshot: SessionRestorableAgentSnapshot
    ) async {
        let sessionId = snapshot.sessionId
        guard let (dataJSON, timeCreated) = queryLatestAssistantMessage(db: db, sessionId: sessionId),
              !dataJSON.isEmpty else {
            return
        }

        let dedupeKey = "\(panelKey.workspaceId.uuidString):\(panelKey.panelId.uuidString):\(sessionId)"
        let fingerprint = (timeCreated, dataJSON.count)

        if await openCodeCompletionTracker.updateFingerprint(fingerprint, for: dedupeKey) {
            emitOpenCodeCompletionNotification(
                panelKey: panelKey,
                workingDirectory: snapshot.workingDirectory,
                dataJSON: dataJSON
            )
        }
    }

    private static func queryLatestAssistantMessage(
        db: OpaquePointer,
        sessionId: String
    ) -> (dataJSON: String, timeCreated: Int64)? {
        let sql = """
            SELECT data, time_created FROM message
            WHERE session_id = ? AND data LIKE '%"role":"assistant"%'
            ORDER BY time_created DESC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_FN)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let dataText = SessionIndexStore.sqliteText(stmt, 0) ?? ""
        let timeCreated = sqlite3_column_int64(stmt, 1)

        return (dataText, timeCreated)
    }

    private static func emitOpenCodeCompletionNotification(
        panelKey: PanelKey,
        workingDirectory: String?,
        dataJSON: String
    ) {
        let body = extractAssistantText(from: dataJSON) ?? String(localized: "opencode.completion.fallbackBody", defaultValue: "Agent produced a new response.")
        let subtitle = workingDirectory.map { ($0 as NSString).lastPathComponent } ?? String(localized: "opencode.completion.subtitle", defaultValue: "Agent")

        Task { @MainActor in
            TerminalNotificationStore.shared.addNotification(
                tabId: panelKey.workspaceId,
                surfaceId: panelKey.panelId,
                title: String(localized: "opencode.completion.title", defaultValue: "Agent completed"),
                subtitle: subtitle,
                body: body
            )
        }
    }

    private static func extractAssistantText(from dataJSON: String) -> String? {
        guard let data = dataJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func collectText(from root: Any) -> String? {
            if let str = root as? [String], !str.isEmpty {
                return str.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }.joined(separator: " ")
            }
            if let str = root as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let dict = root as? [String: Any] {
                if let parts = dict["parts"] as? [[String: Any]] {
                    let texts = parts.compactMap { collectText(from: $0) }
                    if !texts.isEmpty { return texts.joined(separator: " ") }
                }
                if let content = dict["content"] as? String {
                    return collectText(from: content)
                }
                if let contentItems = dict["content"] as? [[String: Any]] {
                    let texts = contentItems.compactMap { collectText(from: $0) }
                    if !texts.isEmpty { return texts.joined(separator: " ") }
                }
                if let text = dict["text"] as? String {
                    return collectText(from: text)
                }
                return nil
            }
            if let arr = root as? [Any] {
                let texts = arr.compactMap { collectText(from: $0) }
                if !texts.isEmpty { return texts.joined(separator: " ") }
            }
            return nil
        }

        guard let text = collectText(from: obj) else { return nil }

        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.isEmpty { return nil }
        if collapsed.count <= 240 { return collapsed }
        return String(collapsed.prefix(240))
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

    private static func wrapperLooksLikeNodeRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node":
            return true
        default:
            return false
        }
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
        guard !expectedNames.isEmpty || !argvContains.isEmpty else { return false }
        let processNameMatch = expectedNames.isEmpty || expectedNames.contains { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
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
            return process.arguments.nonOptionValue(afterOption: option)
        case .piSessionFile:
            if let session = process.arguments.nonOptionValue(afterOption: "--session") {
                return PiSessionLocator.resolvedSessionPath(
                    session,
                    for: process,
                    registration: registration,
                    fileManager: fileManager
                ) ?? session
            }
            return PiSessionLocator.latestSessionPath(for: process, registration: registration, fileManager: fileManager)
        case .grokSessionDirectory:
            if let session = process.arguments.grokResumeSessionID {
                return session
            }
            return nil
        }
    }
}

private extension CmuxTopProcessSnapshot {
    func cmuxScopedProcessIDs(for key: RestorableAgentSessionIndex.PanelKey) -> Set<Int> {
        Set(
            cmuxScopedProcesses()
                .filter {
                    $0.cmuxWorkspaceID == key.workspaceId &&
                        $0.cmuxSurfaceID == key.panelId
                }
                .map(\.pid)
        )
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
