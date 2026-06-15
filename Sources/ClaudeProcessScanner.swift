import CMUXAgentLaunch
import Darwin
import Foundation

extension RestorableAgentSessionIndex {
    static func processDetectedClaudeSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        fileManager: FileManager,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  let processArguments = processArgumentsProvider(process.pid) else {
                continue
            }
            let observed = ClaudeObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isClaudeProcess else { continue }

            let tail = claudeLaunchTail(observed: observed)
            guard AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) != nil else {
                continue
            }
            let cwd = normalizedClaudeProcessValue(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            guard let transcript = newestClaudeProcessTranscript(
                environment: observed.environment,
                cwd: cwd,
                fileManager: fileManager
            ) else {
                continue
            }
            let executablePath = claudeExecutablePath(observed: observed, environment: observed.environment)
            let arguments = observed.arguments.isEmpty ? [executablePath] : observed.arguments
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: transcript.sessionId,
                workingDirectory: transcript.workingDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: "claude",
                    executablePath: executablePath,
                    arguments: arguments,
                    workingDirectory: transcript.workingDirectory,
                    environment: observed.environment
                )
            )
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            resolved[key] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [],
                sessionIDSource: .inferredLatestSessionFile
            )
        }

        return resolved
    }

    private static func claudeExecutablePath(
        observed: ClaudeObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        let argumentExecutable = observed.claudeExecutableArgument
        if let argumentExecutable, argumentExecutable.contains("/") {
            return argumentExecutable
        }
        if let argumentExecutable,
           let resolved = claudeExecutablePath(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           ClaudeObservedAgentProcess.argumentLooksLikeClaude(processPath) {
            return processPath
        }
        if let resolved = claudeExecutablePath(named: "claude", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "claude"
    }

    private static func claudeLaunchTail(observed: ClaudeObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.claudeExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        guard observed.processIdentityLooksLikeClaude else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    private static func newestClaudeProcessTranscript(
        environment: [String: String],
        cwd: String?,
        fileManager: FileManager
    ) -> (sessionId: String, workingDirectory: String?)? {
        guard let cwd else { return nil }
        var best: (sessionId: String, workingDirectory: String, modifiedAt: TimeInterval)?
        for root in claudeConfigRoots(environment: environment, fileManager: fileManager) {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for workingDirectory in claudeWorkingDirectoryCandidates(cwd) {
                let projectDir = (projectsRoot as NSString)
                    .appendingPathComponent(encodeClaudeProjectDir(workingDirectory))
                guard let children = try? fileManager.contentsOfDirectory(atPath: projectDir) else {
                    continue
                }
                for child in children where child.hasSuffix(".jsonl") {
                    let sessionId = String(child.dropLast(".jsonl".count))
                    guard claudeSessionIdIsSafeProcessFilename(sessionId) else { continue }
                    let path = (projectDir as NSString).appendingPathComponent(child)
                    guard regularNonEmptyProcessFileExists(atPath: path, fileManager: fileManager) else {
                        continue
                    }
                    let modifiedAt = ((try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                        .timeIntervalSince1970 ?? 0
                    if best == nil || modifiedAt > best!.modifiedAt {
                        best = (sessionId, workingDirectory, modifiedAt)
                    }
                }
            }
        }
        guard let best else { return nil }
        return (best.sessionId, best.workingDirectory)
    }

    private static func claudeConfigRoots(
        environment: [String: String],
        fileManager: FileManager
    ) -> [String] {
        if let configured = normalizedClaudeProcessValue(environment["CLAUDE_CONFIG_DIR"]) {
            return [ClaudeConfigDirectoryPath.preferredPath(configured, fileManager: fileManager)]
        }

        let homeDirectory = NSHomeDirectory()
        var roots: [String] = []
        var seen = Set<String>()
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: accountRoot, isDirectory: &isDirectory),
           isDirectory.boolValue,
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
        return roots
    }

    private static func claudeWorkingDirectoryCandidates(_ cwd: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        func append(_ path: String?) {
            guard let path = normalizedClaudeProcessValue(path),
                  seen.insert(path).inserted else {
                return
            }
            candidates.append(path)
        }

        append(cwd)
        append((cwd as NSString).standardizingPath)
        append(realpathCandidate(cwd))
        if cwd == "/tmp" {
            append("/private/tmp")
        } else if cwd.hasPrefix("/tmp/") {
            append("/private" + cwd)
        } else if cwd == "/private/tmp" {
            append("/tmp")
        } else if cwd.hasPrefix("/private/tmp/") {
            append(String(cwd.dropFirst("/private".count)))
        }
        return candidates
    }

    private static func realpathCandidate(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func claudeExecutablePath(named name: String, environment: [String: String]) -> String? {
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

    private static func regularNonEmptyProcessFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func claudeSessionIdIsSafeProcessFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    private static func normalizedClaudeProcessValue(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

private struct ClaudeObservedAgentProcess: Sendable {
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

    var isClaudeProcess: Bool {
        processIdentityLooksLikeClaude || claudeExecutableArgumentIndex != nil
    }

    var processIdentityLooksLikeClaude: Bool {
        executableBasenames.contains { basename in
            Self.argumentLooksLikeClaude(basename)
        }
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
        guard executableBasenames.contains(where: Self.wrapperLooksLikeJavaScriptRuntime),
              let scriptIndex = Self.javaScriptRuntimeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeClaude(arguments[scriptIndex]) ? scriptIndex : nil
    }

    static func argumentLooksLikeClaude(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "claude" ||
            basename == "claude.exe" ||
            basename == "claude.js" ||
            normalized.contains("@anthropic-ai/claude-code") ||
            normalized.contains("claude-code")
    }

    private static func wrapperLooksLikeJavaScriptRuntime(_ basename: String) -> Bool {
        switch basename.lowercased() {
        case "node", "bun", "deno", "tsx", "ts-node":
            return true
        default:
            return false
        }
    }

    private static func javaScriptRuntimeScriptArgumentIndex(_ arguments: [String]) -> Int? {
        guard let first = arguments.first,
              wrapperLooksLikeJavaScriptRuntime((first as NSString).lastPathComponent) else {
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
                index += 1 + nodeOptionValueCount(argument)
                continue
            }
            return index
        }
        return nil
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
