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
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  workingDirectory: workingDirectory,
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
        let cwd = !includeWorkingDirectoryPrefix || customRegistration?.cwd == .ignore
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
        workingDirectory: String?,
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
            let arguments = customResumeArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
            return arguments.isEmpty ? nil : arguments
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
        case .pi:
            return resumeWithOption(
                kind: "pi",
                launchCommand: launchCommand,
                fallbackExecutable: "pi",
                option: "--session",
                sessionId: sessionId
            )
        case .amp:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "amp")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "amp", args: original.tail) else { return nil }
            return [original.executable, "threads", "continue"] + preserved + [sessionId]
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
        case .hermesAgent:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "hermes")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "hermes-agent", args: original.tail) else { return nil }
            return [original.executable] + preserved + ["--resume", sessionId]
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
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        let templateParts = splitShellWords(registration.resumeCommand)
        guard !templateParts.isEmpty else { return [] }
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
            "cwd": normalized(workingDirectory ?? launchCommand?.workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    private static func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
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
    var registration: CmuxVaultAgentRegistration? = nil

    var resumeCommand: String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
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
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    var isRestorable: Bool?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(snapshotsByPanel: [:])

    struct PanelKey: Hashable, Sendable {
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
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            let detectedSnapshots = processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager
            )
            return load(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: detectedSnapshots
            )
        }.value
    }

    private static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)]
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        let claudeTranscriptLookup = ClaudeTranscriptLookupCache(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }

        for (kind, registration) in hookKinds {
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
                      let panelId = UUID(uuidString: record.surfaceId),
                      hookRecordStillBelongsToLiveAgent(
                          record,
                          kind: kind,
                          workspaceId: workspaceId,
                          panelId: panelId
                      ),
                      hookRecordIsRestorable(
                          record,
                          kind: kind,
                          fileManager: fileManager,
                          claudeTranscriptLookup: claudeTranscriptLookup
                      ) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd),
                    launchCommand: record.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = (snapshot: snapshot, updatedAt: record.updatedAt)
            }
        }

        for (key, detected) in detectedSnapshots {
            if let existing = resolved[key], existing.updatedAt > detected.updatedAt {
                continue
            }
            resolved[key] = detected
        }

        return RestorableAgentSessionIndex(snapshotsByPanel: resolved.mapValues(\.snapshot))
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    private static func hookRecordIsRestorable(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        fileManager: FileManager,
        claudeTranscriptLookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard kind == .claude else {
            return record.isRestorable != false
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return true
        }
        return claudeTranscriptExists(for: record, fileManager: fileManager, lookup: claudeTranscriptLookup)
    }

    private static func claudeTranscriptExists(
        for record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return false }

        let cwd = normalizedWorkingDirectory(record.cwd)
            ?? normalizedWorkingDirectory(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               claudeTranscriptFileExists(
                   configRoot: root,
                   projectDirName: encodeClaudeProjectDir(cwd),
                   sessionId: sessionId,
                   fileManager: fileManager
               ) {
                return true
            }
            if claudeTranscriptFileExistsInAnyProject(
                configRoot: root,
                sessionId: sessionId,
                fileManager: fileManager,
                lookup: lookup
            ) {
                return true
            }
        }
        return false
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    static func encodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    private static func claudeTranscriptFileExists(
        configRoot: String,
        projectDirName: String,
        sessionId: String,
        fileManager: FileManager
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirName)
        let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        return regularNonEmptyFileExists(atPath: path, fileManager: fileManager)
    }

    private static func claudeTranscriptFileExistsInAnyProject(
        configRoot: String,
        sessionId: String,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        for projectDir in lookup.projectDirs(configRoot: configRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: path, fileManager: fileManager) {
                return true
            }
        }
        return false
    }

    private final class ClaudeTranscriptLookupCache {
        private let homeDirectory: String
        private let fileManager: FileManager
        private var defaultRoots: [String]?
        private var projectDirsByConfigRoot: [String: [String]] = [:]

        init(homeDirectory: String, fileManager: FileManager) {
            self.homeDirectory = homeDirectory
            self.fileManager = fileManager
        }

        func configRoots(for record: RestorableAgentHookSessionRecord) -> [String] {
            if let configured = RestorableAgentSessionIndex.normalizedNonEmptyValue(
                record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
            ) {
                return [
                    ClaudeConfigDirectoryPath.preferredPath(
                        configured,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory
                    ),
                ]
            }

            if let defaultRoots {
                return defaultRoots
            }

            var roots: [String] = []
            var seen: Set<String> = []
            func appendRoot(_ path: String) {
                let standardized = (path as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { return }
                roots.append(standardized)
            }

            let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
            if directoryExists(atPath: accountRoot),
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

            defaultRoots = roots
            return roots
        }

        func projectDirs(configRoot: String) -> [String] {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            if let cached = projectDirsByConfigRoot[standardizedRoot] {
                return cached
            }

            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot),
                  let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
                projectDirsByConfigRoot[standardizedRoot] = []
                return []
            }

            projectDirsByConfigRoot[standardizedRoot] = projectDirs
            return projectDirs
        }

        private func directoryExists(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
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

    private static func hookRecordStillBelongsToLiveAgent(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        workspaceId: UUID,
        panelId: UUID
    ) -> Bool {
        guard let pid = record.pid else {
            return true
        }
        guard pid > 0,
              let process = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid),
              process.environmentUUID(forKey: "CMUX_WORKSPACE_ID") == workspaceId,
              process.environmentUUID(forKey: "CMUX_SURFACE_ID") == panelId else {
            return false
        }

        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return false
        }

        guard let recordedExecutable = recordedExecutableBasename(record),
              let liveExecutable = process.arguments.first.map(executableBasename) else {
            return true
        }
        return liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func recordedExecutableBasename(_ record: RestorableAgentHookSessionRecord) -> String? {
        let executable = normalizedProcessValue(record.launchCommand?.executablePath)
            ?? normalizedProcessValue(record.launchCommand?.arguments.first)
        return executable.map(executableBasename)
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private static func normalizedProcessValue(_ value: String?) -> String? {
        normalizedNonEmptyValue(value)
    }

    private static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]) {
        self.snapshotsByPanel = snapshotsByPanel
    }
}

private extension CmuxTopProcessArguments {
    func environmentUUID(forKey key: String) -> UUID? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}
