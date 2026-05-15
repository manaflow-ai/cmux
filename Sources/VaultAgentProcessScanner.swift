import Foundation
import SQLite3

extension RestorableAgentSessionIndex {
    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var resolved = processDetectedOpenCodeSnapshots(
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            fileManager: fileManager
        )

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
                  let processArguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process.pid) else {
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
                    launcher: registration.id,
                    executablePath: executablePath,
                    arguments: arguments,
                    workingDirectory: cwd,
                    environment: observed.environment,
                    capturedAt: capturedAt,
                    source: "process"
                ),
                registration: registration
            )
            resolved[PanelKey(workspaceId: workspaceId, panelId: panelId)] = (snapshot: snapshot, updatedAt: capturedAt)
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

    static func openCodeFallbackSessionIdForProcess(
        arguments: [String],
        latestSessionIdForSolePanel: String?,
        sameWorkingDirectoryPanelCount: Int
    ) -> String? {
        if arguments.hasOpenCodeForkFlag {
            guard sameWorkingDirectoryPanelCount == 1 else { return nil }
            guard let latestSessionIdForSolePanel else { return nil }
            let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s")
            guard explicitSessionId != latestSessionIdForSolePanel else { return nil }
            return latestSessionIdForSolePanel
        }
        if let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s") {
            return explicitSessionId
        }
        guard sameWorkingDirectoryPanelCount == 1 else { return nil }
        return latestSessionIdForSolePanel
    }

    private static func processDetectedOpenCodeSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        var sessionByWorkingDirectory: [String: String?] = [:]
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

            let cwd = normalized(observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"])
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
            let hasExplicitSessionId = process.observed.arguments.value(afterOption: "--session") != nil ||
                process.observed.arguments.value(afterOption: "-s") != nil
            let hasForkFlag = process.observed.arguments.hasOpenCodeForkFlag
            let latestSessionId: String?
            if (hasExplicitSessionId && !hasForkFlag) || sameWorkingDirectoryPanelCount != 1 || process.workingDirectory == nil {
                latestSessionId = nil
            } else if let cached = sessionByWorkingDirectory[process.workingDirectoryKey] {
                latestSessionId = cached
            } else {
                latestSessionId = latestOpenCodeSessionId(
                    workingDirectory: process.workingDirectory,
                    fileManager: fileManager
                )
                sessionByWorkingDirectory[process.workingDirectoryKey] = latestSessionId
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
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .opencode,
                sessionId: sessionId,
                workingDirectory: process.workingDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "opencode",
                    executablePath: executablePath,
                    arguments: [executablePath],
                    workingDirectory: process.workingDirectory,
                    environment: process.observed.environment,
                    capturedAt: capturedAt,
                    source: "process"
                )
            )
            resolved[process.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt
            )
        }

        return resolved
    }

    private static func openCodeExecutablePath(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        let argumentExecutable = observed.arguments.first(where: { argument in
            VaultObservedAgentProcess.argumentLooksLikeOpenCode(argument)
        })
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

        let cwd = normalized(workingDirectory).map { ($0 as NSString).standardizingPath }
        let sql: String
        if cwd != nil {
            sql = """
                SELECT id FROM session
                WHERE directory = ?
                ORDER BY time_updated DESC
                LIMIT 1
                """
        } else {
            sql = """
                SELECT id FROM session
                ORDER BY time_updated DESC
                LIMIT 1
                """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if let cwd {
            let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, cwd, -1, SQLITE_TRANSIENT_FN)
        }

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
        executableBasenames.contains { basename in
            let normalized = basename.lowercased()
            return normalized == "opencode" ||
                normalized == ".opencode" ||
                normalized == "opencode-ai"
        } || arguments.contains { argument in
            Self.argumentLooksLikeOpenCode(argument)
        }
    }

    static func argumentLooksLikeOpenCode(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "opencode" ||
            basename == ".opencode" ||
            basename == "opencode-ai" ||
            pathComponents.contains("opencode-ai")
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

private extension Array where Element == String {
    var hasOpenCodeForkFlag: Bool {
        contains { $0 == "--fork" || $0.hasPrefix("--fork=") }
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
