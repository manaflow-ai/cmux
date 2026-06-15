import CMUXAgentLaunch
import Foundation

extension RestorableAgentSessionIndex {
    static func processDetectedCodexSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
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
            let observed = CodexObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            guard observed.isCodexProcess else { continue }

            let tail = codexLaunchTail(observed: observed)
            guard let sessionId = codexSessionId(in: tail)
                    ?? normalizedCodexProcessValue(observed.environment["CODEX_THREAD_ID"]),
                  AgentLaunchSanitizer.preservedCodexForkArguments(args: tail) != nil else {
                continue
            }
            let executablePath = codexExecutablePath(observed: observed, environment: processArguments.environment)
            let cwd = normalizedCodexProcessValue(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: "codex",
                    executablePath: executablePath,
                    arguments: [executablePath] + tail,
                    workingDirectory: cwd,
                    environment: observed.environment
                )
            )
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            resolved[key] = (
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [],
                sessionIDSource: .explicit
            )
        }

        return resolved
    }

    private static func codexExecutablePath(
        observed: CodexObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        let argumentExecutable = observed.codexExecutableArgument
        if let argumentExecutable, argumentExecutable.contains("/") {
            return argumentExecutable
        }
        if let argumentExecutable,
           let resolved = executablePath(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           CodexObservedAgentProcess.argumentLooksLikeCodex(processPath) {
            return processPath
        }
        if let resolved = executablePath(named: "codex", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "codex"
    }

    private static func codexLaunchTail(observed: CodexObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.codexExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        guard observed.processIdentityLooksLikeCodex else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    private static func codexSessionId(in arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            guard argument == "resume" || argument == "fork" else { continue }
            let nextIndex = arguments.index(after: index)
            guard nextIndex < arguments.endIndex,
                  let value = normalizedCodexProcessValue(arguments[nextIndex]),
                  !value.hasPrefix("-") else {
                return nil
            }
            return value
        }
        return nil
    }

    private static func executablePath(named name: String, environment: [String: String]) -> String? {
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

    private static func normalizedCodexProcessValue(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

private struct CodexObservedAgentProcess: Sendable {
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

    var isCodexProcess: Bool {
        processIdentityLooksLikeCodex || codexExecutableArgumentIndex != nil
    }

    var processIdentityLooksLikeCodex: Bool {
        executableBasenames.contains { basename in
            Self.argumentLooksLikeCodex(basename)
        }
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
        guard executableBasenames.contains(where: Self.wrapperLooksLikeJavaScriptRuntime),
              let scriptIndex = Self.javaScriptRuntimeScriptArgumentIndex(arguments) else {
            return nil
        }
        return Self.argumentLooksLikeCodex(arguments[scriptIndex]) ? scriptIndex : nil
    }

    static func argumentLooksLikeCodex(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "codex" ||
            basename == ".codex" ||
            basename == "codex.js" ||
            normalized.contains("@openai/codex")
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
