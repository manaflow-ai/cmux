import Foundation

extension RestorableAgentSessionIndex {
    static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        guard !registry.registrations.isEmpty else { return [:] }
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
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
