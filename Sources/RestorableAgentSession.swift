import Foundation
import CMUXAgentLaunch

fileprivate func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum AgentResumeCommandBuilder {
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR"
    ]
    static func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil
    ) -> String? {
        let registry = registrationOverride.map {
            CmuxVaultAgentRegistry(registrations: [$0])
        } ?? CmuxVaultAgentRegistry.load(
            workingDirectory: workingDirectory ?? launchCommand?.workingDirectory
        )
        let customRegistration = registrationOverride ?? kind.customAgentID.flatMap { registry.registration(id: $0) }
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  customRegistration: customRegistration
              ),
              !argv.isEmpty else {
            return nil
        }

        var commandParts: [String] = []
        let environmentParts = launchEnvironmentParts(kind: kind, environment: launchCommand?.environment)
        if !environmentParts.isEmpty {
            commandParts.append("env")
            commandParts.append(contentsOf: environmentParts)
        }
        commandParts.append(contentsOf: argv)

        var shellCommand = commandParts.map(shellSingleQuoted).joined(separator: " ")
        let cwd = customRegistration?.cwd == .ignore
            ? nil
            : normalized(workingDirectory ?? launchCommand?.workingDirectory)
        if let cwd {
            shellCommand = "cd \(shellSingleQuoted(cwd)) && \(shellCommand)"
        }
        return shellCommand
    }

    private static func launchEnvironmentParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else {
            return []
        }

        var environmentParts: [String] = []
        var preservedClaudeAuthSelectionEnvironmentKeys: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        for key in selectedEnvironment.keys.sorted() {
            guard let value = selectedEnvironment[key] else { continue }
            environmentParts.append("\(key)=\(value)")
            if kind == .claude,
               claudeAuthSelectionEnvironmentKeys.contains(key) {
                preservedClaudeAuthSelectionEnvironmentKeys.append(key)
            }
        }
        if !preservedClaudeAuthSelectionEnvironmentKeys.isEmpty {
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1")
            environmentParts.append(
                "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=\(preservedClaudeAuthSelectionEnvironmentKeys.joined(separator: ","))"
            )
        }
        return environmentParts
    }

    private static func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: args) else { return nil }
            return [original.executable, "omo", "--session", sessionId] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        if case .custom = kind {
            guard let customRegistration else { return nil }
            return customResumeArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand
            )
        }

        switch kind {
        case .claude:
            return resumeWithOption(
                kind: "claude",
                launchCommand: launchCommand,
                fallbackExecutable: "claude",
                option: "--resume",
                sessionId: sessionId
            )
        case .codex:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "codex", args: original.tail) else { return nil }
            return [original.executable, "resume"] + preserved + [sessionId]
        case .cursor:
            return resumeWithOption(
                kind: "cursor",
                launchCommand: launchCommand,
                fallbackExecutable: "cursor-agent",
                option: "--resume",
                sessionId: sessionId
            )
        case .gemini:
            return resumeWithOption(
                kind: "gemini",
                launchCommand: launchCommand,
                fallbackExecutable: "gemini",
                option: "--resume",
                sessionId: sessionId
            )
        case .opencode:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: original.tail) else { return nil }
            return [original.executable, "--session", sessionId] + preserved
        case .rovodev:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "acli")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "rovodev", args: original.tail) else { return nil }
            return [original.executable, "rovodev", "run", "--restore", sessionId] + preserved
        case .copilot:
            return resumeWithOption(
                kind: "copilot",
                launchCommand: launchCommand,
                fallbackExecutable: "copilot",
                option: "--resume",
                sessionId: sessionId
            )
        case .codebuddy:
            return resumeWithOption(
                kind: "codebuddy",
                launchCommand: launchCommand,
                fallbackExecutable: "codebuddy",
                option: "--resume",
                sessionId: sessionId
            )
        case .factory:
            return resumeWithOption(
                kind: "factory",
                launchCommand: launchCommand,
                fallbackExecutable: "droid",
                option: "--resume",
                sessionId: sessionId
            )
        case .qoder:
            return resumeWithOption(
                kind: "qoder",
                launchCommand: launchCommand,
                fallbackExecutable: "qodercli",
                option: "--resume",
                sessionId: sessionId
            )
        case .custom:
            return nil
        }
    }

    private static func customResumeArguments(
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        let templateParts = splitShellWords(registration.resumeCommand)
        guard !templateParts.isEmpty else { return nil }
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: registration.defaultExecutable
        )
        let sessionDirectory = normalized(registration.sessionDirectory).map {
            ($0 as NSString).expandingTildeInPath
        }
        let replacements: [String: String] = [
            "sessionId": sessionId,
            "sessionPath": sessionId,
            "executable": original.executable,
            "cwd": normalized(launchCommand?.workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        let resolved = templateParts.compactMap { part -> String? in
            var value = part
            for (key, replacement) in replacements {
                value = value.replacingOccurrences(of: "{{\(key)}}", with: replacement)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return resolved.isEmpty ? nil : resolved
    }

    private static func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
        finishWord()
        return words
    }

    private static func resumeWithOption(
        kind: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String,
        option: String,
        sessionId: String
    ) -> [String]? {
        let original = commandParts(launchCommand: launchCommand, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: original.tail) else {
            return nil
        }
        return [original.executable, option, sessionId] + preserved
    }

    private static func commandParts(
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let arguments = launchCommand?.arguments ?? []
        let executable = normalized(launchCommand?.executablePath)
            ?? arguments.first
            ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?

    var resumeCommand: String? {
        kind.resumeCommand(
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let command = resumeCommand else { return nil }

        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            let contents = """
            #!/bin/zsh
            rm -f -- "$0" 2>/dev/null || true
            \(command)
            """
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(snapshotsByPanel: [:])

    private struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private let snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        snapshotsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds = RestorableAgentKind.allCases + registry.registrations.compactMap {
            builtInKindIDs.contains($0.id) ? nil : .custom($0.id)
        }

        for kind in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let panelId = UUID(uuidString: record.surfaceId) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd),
                    launchCommand: record.launchCommand
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = (snapshot: snapshot, updatedAt: record.updatedAt)
            }
        }

        for (key, detected) in processDetectedSnapshots(
            registry: registry,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            if let existing = resolved[key], existing.updatedAt > detected.updatedAt {
                continue
            }
            resolved[key] = detected
        }

        return RestorableAgentSessionIndex(snapshotsByPanel: resolved.mapValues(\.snapshot))
    }

    private static func processDetectedSnapshots(
        registry: CmuxVaultAgentRegistry,
        homeDirectory: String,
        fileManager: FileManager
    ) -> [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] {
        guard !registry.registrations.isEmpty else { return [:] }
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]

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
            let cwd = normalizedWorkingDirectory(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"]
                    ?? observed.environment["PWD"]
            )
            let processRegistry = cwd == nil
                ? registry
                : CmuxVaultAgentRegistry.load(
                    homeDirectory: homeDirectory,
                    workingDirectory: cwd,
                    environment: observed.environment,
                    fileManager: fileManager
                )
            guard let registration = processRegistry.registrations.first(where: { $0.detect.matches(observed) }),
                  let sessionId = registration.sessionIdSource.sessionId(
                      from: observed,
                      registration: registration,
                      fileManager: fileManager
                  ) else {
                continue
            }

            let executablePath = normalizedWorkingDirectory(observed.arguments.first)
                ?? normalizedWorkingDirectory(process.path)
                ?? registration.defaultExecutable
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
                )
            )
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            resolved[key] = (snapshot: snapshot, updatedAt: capturedAt)
        }

        return resolved
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]) {
        self.snapshotsByPanel = snapshotsByPanel
    }
}

private struct VaultObservedAgentProcess: Sendable {
    let processName: String
    let processPath: String?
    let arguments: [String]
    let environment: [String: String]

    var executableBasenames: [String] {
        var names: [String] = []
        if !processName.isEmpty {
            names.append(processName)
        }
        if let processPath, !processPath.isEmpty {
            names.append((processPath as NSString).lastPathComponent)
        }
        if let first = arguments.first, !first.isEmpty {
            names.append((first as NSString).lastPathComponent)
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

private extension CmuxVaultAgentDetectRule {
    func matches(_ process: VaultObservedAgentProcess) -> Bool {
        if let processName, !processName.isEmpty,
           process.executableBasenames.contains(where: {
               $0.compare(processName, options: [.caseInsensitive, .literal]) == .orderedSame
           }) {
            return true
        }
        guard !argvContains.isEmpty else { return false }
        return argvContains.allSatisfy { needle in
            if needle.contains("/") || needle.contains(" ") {
                let joinedArguments = process.arguments.joined(separator: "\u{0}")
                return joinedArguments.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            return process.arguments.contains { argument in
                argument.compare(needle, options: [.caseInsensitive, .literal]) == .orderedSame
                    || (argument as NSString).lastPathComponent.compare(
                        needle,
                        options: [.caseInsensitive, .literal]
                    ) == .orderedSame
            }
        }
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
            return PiSessionLocator.latestSessionPath(
                for: process,
                registration: registration,
                fileManager: fileManager
            )
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
                let value = String(argument.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
        newestJSONLFile(
            in: candidateSessionDirectory(
                for: process,
                registration: registration
            ),
            fileManager: fileManager
        )?.path
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
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate else {
                continue
            }
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
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate else {
                continue
            }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }
}
