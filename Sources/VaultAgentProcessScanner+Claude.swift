import Foundation
import CMUXAgentLaunch

extension RestorableAgentSessionIndex {
    static func processLooksLikeClaude(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Bool {
        VaultObservedAgentProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        ).isClaudeProcess
    }

    static func claudeSessionIdForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        return claudeSessionId(observed: observed, environment: environment)
    }

    static func claudeLaunchArgumentsForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> [String]? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        let executablePath = claudeExecutablePath(observed: observed, environment: environment)
        return claudeLaunchArguments(observed: observed, executablePath: executablePath)
    }

    static func claudeLaunchCommandForProcess(
        arguments: [String],
        environment: [String: String]
    ) -> AgentLaunchCommandSnapshot? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        let executablePath = claudeExecutablePath(observed: observed, environment: environment)
        return claudeLaunchCommand(
            observed: observed,
            executablePath: executablePath,
            tail: claudeLaunchTail(observed: observed),
            workingDirectory: normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"])
        )
    }

    static func processDetectedClaudeSnapshots(
        candidates: [RestorableAgentProcessDetectionCandidate],
        capturedAt: TimeInterval,
        fileManager: FileManager
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
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
            let launchTail = claudeLaunchTail(observed: observed)
            guard observed.isClaudeProcess,
                  claudeProcessPIDMatchesEnvironment(process, environment: processArguments.environment),
                  let sessionId = claudeSessionId(
                      tail: launchTail,
                      environment: processArguments.environment,
                      processID: process.pid,
                      fileManager: fileManager
                  ) else {
                continue
            }

            let executablePath = claudeExecutablePath(
                observed: observed,
                environment: processArguments.environment
            )
            let workingDirectory = normalized(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            guard let launchCommand = claudeLaunchCommand(
                observed: observed,
                executablePath: executablePath,
                tail: launchTail,
                workingDirectory: workingDirectory
            ) else {
                sentryBreadcrumb(
                    "session.process_detected.claude.skip",
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
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: workingDirectory,
                launchCommand: launchCommand
            )
            resolved[candidate.panelKey] = (
                snapshot: snapshot,
                updatedAt: capturedAt
            )
            selectedCandidateByPanelKey[candidate.panelKey] = (
                source: candidate.source,
                isForeground: isForeground,
                matchesFallbackScope: candidate.matchesFallbackScope
            )
        }

        return resolved
    }

    private static func claudeSessionId(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String? {
        claudeSessionId(tail: claudeLaunchTail(observed: observed), environment: environment)
    }

    private static func claudeProcessPIDMatchesEnvironment(
        _ process: CmuxTopProcessInfo,
        environment: [String: String]
    ) -> Bool {
        guard let rawPID = normalized(environment["CMUX_CLAUDE_PID"]) else {
            return true
        }
        return Int(rawPID) == process.pid
    }

    private static func claudeSessionId(
        tail: [String],
        environment: [String: String]
    ) -> String? {
        claudeSessionId(
            tail: tail,
            environment: environment,
            processID: nil,
            fileManager: .default
        )
    }

    private static func claudeSessionId(
        tail: [String],
        environment: [String: String],
        processID: Int?,
        fileManager: FileManager
    ) -> String? {
        let environmentSessionId = normalized(environment["CLAUDE_SESSION_ID"])
        let resumeSessionId = claudeResumeSessionIdValue(afterOption: "--resume", in: tail)
            ?? claudeResumeSessionIdValue(afterOption: "-r", in: tail)
        let processSessionFileSessionId = claudeSessionIdFromProcessSessionFile(
            processID: processID,
            environment: environment,
            fileManager: fileManager
        )
        if tail.hasClaudeForkSessionFlag {
            let nonParentEnvironmentSessionId = environmentSessionId == resumeSessionId
                ? nil
                : environmentSessionId
            return claudeSessionIdValue(afterOption: "--session-id", in: tail)
                ?? processSessionFileSessionId
                ?? nonParentEnvironmentSessionId
                ?? resumeSessionId
        }
        return claudeSessionIdValue(afterOption: "--session-id", in: tail)
            ?? resumeSessionId
            ?? environmentSessionId
            ?? processSessionFileSessionId
    }

    private static func claudeSessionIdValue(afterOption option: String, in arguments: [String]) -> String? {
        guard let value = arguments.value(afterOption: option),
              !value.hasPrefix("-") else {
            return nil
        }
        return value
    }

    private static func claudeResumeSessionIdValue(afterOption option: String, in arguments: [String]) -> String? {
        guard let value = claudeSessionIdValue(afterOption: option, in: arguments),
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value
    }

    private struct ClaudeProcessSessionRecord: Decodable {
        let pid: Int?
        let sessionId: String?
        let cwd: String?
    }

    private static func claudeSessionIdFromProcessSessionFile(
        processID: Int?,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        guard let processID,
              let configDir = claudeConfigDirectory(environment: environment, fileManager: fileManager) else {
            return nil
        }
        let sessionURL = URL(fileURLWithPath: configDir, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(processID).json", isDirectory: false)
        guard let data = fileManager.contents(atPath: sessionURL.path),
              let record = try? JSONDecoder().decode(ClaudeProcessSessionRecord.self, from: data),
              record.pid == nil || record.pid == processID,
              let sessionId = normalized(record.sessionId),
              UUID(uuidString: sessionId) != nil else {
            return nil
        }
        if let processCWD = normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"]),
           let recordCWD = normalized(record.cwd),
           (processCWD as NSString).standardizingPath != (recordCWD as NSString).standardizingPath {
            return nil
        }
        guard claudeTranscriptExists(
            configDirectory: configDir,
            sessionId: sessionId,
            workingDirectory: normalized(record.cwd ?? environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"]),
            fileManager: fileManager
        ) else {
            return nil
        }
        return sessionId
    }

    private static func claudeTranscriptExists(
        configDirectory: String,
        sessionId: String,
        workingDirectory: String?,
        fileManager: FileManager
    ) -> Bool {
        guard claudeSessionIdIsSafeFilename(sessionId) else { return false }
        let projectsURL = URL(fileURLWithPath: configDirectory, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        if let workingDirectory = normalized(workingDirectory) {
            let projectURL = projectsURL.appendingPathComponent(
                claudeProjectDirectoryName(for: workingDirectory),
                isDirectory: true
            )
            if regularNonEmptyFileExists(
                atPath: projectURL.appendingPathComponent("\(sessionId).jsonl").path,
                fileManager: fileManager
            ) {
                return true
            }
        }
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for projectDirectory in projectDirectories {
            let values = try? projectDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != false else { continue }
            if regularNonEmptyFileExists(
                atPath: projectDirectory.appendingPathComponent("\(sessionId).jsonl").path,
                fileManager: fileManager
            ) {
                return true
            }
        }
        return false
    }

    private static func claudeProjectDirectoryName(for workingDirectory: String) -> String {
        (workingDirectory as NSString).standardizingPath.replacingOccurrences(of: "/", with: "-")
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
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

    private static func claudeConfigDirectory(
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        let home = normalized(environment["HOME"]) ?? NSHomeDirectory()
        let rawConfigDir = normalized(environment["CLAUDE_CONFIG_DIR"])
            ?? ((home as NSString).appendingPathComponent(".claude") as String)
        return ClaudeConfigDirectoryPath.preferredPath(
            rawConfigDir,
            fileManager: fileManager,
            homeDirectory: home
        )
    }

    private static func claudeExecutablePath(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        if let launchExecutable = normalized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) {
            return launchExecutable
        }
        let argumentExecutable = observed.claudeExecutableArgument
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
           VaultObservedAgentProcess.argumentLooksLikeClaude(processPath) {
            return processPath
        }
        if let resolved = executablePath(named: "claude", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "claude"
    }

    private static func claudeLaunchArguments(
        observed: VaultObservedAgentProcess,
        executablePath: String,
        tail: [String]? = nil
    ) -> [String]? {
        let tail = tail ?? claudeLaunchTail(observed: observed)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) else {
            return nil
        }
        return [executablePath] + preserved
    }

    private static func claudeLaunchCommand(
        observed: VaultObservedAgentProcess,
        executablePath: String,
        tail: [String],
        workingDirectory: String?
    ) -> AgentLaunchCommandSnapshot? {
        let environment = observed.environment
        let inheritedLauncher = normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        let inheritedArguments = decodeNULSeparatedBase64(environment["CMUX_AGENT_LAUNCH_ARGV_B64"])
        let canonicalInheritedLauncher = inheritedLauncher.flatMap(canonicalClaudeInheritedLauncher)
        if inheritedLauncher != nil,
           canonicalInheritedLauncher == nil {
            return nil
        }
        if let canonicalInheritedLauncher,
           let inheritedArguments {
            guard let sanitizedArguments = AgentLaunchSanitizer.sanitizedLaunchArguments(
                inheritedArguments,
                launcher: canonicalInheritedLauncher,
                fallbackKind: "claude"
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
           !claudeLaunchKindAllowsProcessFallback(inheritedLauncher) {
            return nil
        }

        guard let launchArguments = claudeLaunchArguments(
            observed: observed,
            executablePath: executablePath,
            tail: tail
        ) else {
            return nil
        }
        return AgentLaunchCommandSnapshot(
            processDetectedLauncher: "claude",
            executablePath: executablePath,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    private static func claudeLaunchKindAllowsProcessFallback(_ launcher: String) -> Bool {
        switch normalizedLaunchKind(launcher) {
        case "", "claude":
            return true
        default:
            return false
        }
    }

    private static func canonicalClaudeInheritedLauncher(_ launcher: String) -> String? {
        switch normalizedLaunchKind(launcher) {
        case "claude":
            return "claude"
        case "claudeteams":
            return "claudeTeams"
        default:
            return nil
        }
    }

    private static func claudeLaunchTail(observed: VaultObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.claudeExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        let processIdentityLooksLikeClaude = observed.executableBasenames.contains { basename in
            VaultObservedAgentProcess.argumentLooksLikeClaude(basename)
        }
        guard processIdentityLooksLikeClaude else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

}

extension VaultObservedAgentProcess {
    var isClaudeProcess: Bool {
        processIdentityLooksLikeClaude || claudeExecutableArgumentIndex != nil
    }

    var claudeExecutableArgument: String? {
        guard let index = claudeExecutableArgumentIndex,
              arguments.indices.contains(index) else {
            return nil
        }
        return arguments[index]
    }

    var claudeExecutableArgumentIndex: Int? {
        if let first = arguments.first,
           Self.argumentLooksLikeClaude(first) {
            return 0
        }
        guard executableBasenames.contains(where: Self.wrapperLooksLikeNodeRuntime) else {
            return nil
        }
        guard let scriptIndex = Self.nodeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeClaude(arguments[scriptIndex]) ? scriptIndex : nil
    }

    private var processIdentityLooksLikeClaude: Bool {
        if let processPath,
           Self.argumentLooksLikeClaude(processPath) {
            return true
        }
        return executableBasenames.contains { basename in
            let normalized = basename.lowercased()
            return normalized == "claude" ||
                normalized == "claude-code" ||
                normalized == "claude_code"
        }
    }

    static func argumentLooksLikeClaude(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
            .replacingOccurrences(of: "\\", with: "/")
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "claude" ||
            basename == "claude-code" ||
            basename == "claude_code" ||
            normalized.contains("/@anthropic-ai/claude-code/") ||
            hasClaudeCodeInstallSegment(pathComponents) ||
            normalized.contains("/.local/share/claude/versions/") ||
            normalized.contains("/library/application support/claude/claude-code/")
    }

    private static func hasClaudeCodeInstallSegment(_ pathComponents: [String]) -> Bool {
        guard let index = pathComponents.firstIndex(of: "claude-code") else {
            return false
        }
        if index > 0, pathComponents[index - 1] == "@anthropic-ai" {
            return true
        }

        let prefix = pathComponents.prefix(index)
        let suffix = pathComponents.dropFirst(index + 1)
        guard suffix.contains(where: { $0.hasSuffix(".app") }) else {
            return false
        }
        return prefix.contains("applications") ||
            prefix.contains("caskroom") ||
            prefix.contains("application support")
    }
}

private extension Array where Element == String {
    var hasClaudeForkSessionFlag: Bool {
        contains { $0 == "--fork-session" || $0.hasPrefix("--fork-session=") }
    }
}
