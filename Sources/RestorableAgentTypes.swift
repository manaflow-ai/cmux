import Foundation

enum RestorableAgentKind: Codable, Hashable, Sendable {
    case claude
    case codex
    case cursor
    case gemini
    case opencode
    case rovodev
    case copilot
    case codebuddy
    case factory
    case qoder
    case custom(String)

    static let allCases: [RestorableAgentKind] = [
        .claude,
        .codex,
        .cursor,
        .gemini,
        .opencode,
        .rovodev,
        .copilot,
        .codebuddy,
        .factory,
        .qoder,
    ]

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "cursor": self = .cursor
        case "gemini": self = .gemini
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        case "copilot": self = .copilot
        case "codebuddy": self = .codebuddy
        case "factory": self = .factory
        case "qoder": self = .qoder
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .custom(value)
        }
    }

    var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .copilot: return "copilot"
        case .codebuddy: return "codebuddy"
        case .factory: return "factory"
        case .qoder: return "qoder"
        case .custom(let id): return id
        }
    }

    var customAgentID: String? {
        if case .custom(let id) = self {
            return id
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = RestorableAgentKind(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid restorable agent kind '\(value)'"
                )
            )
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private var hookStoreFilename: String {
        "\(rawValue)-hook-sessions.json"
    }

    func resumeCommand(
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: self,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    func hookStoreFileURL(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let directory: URL
        if let override = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            directory = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".cmuxterm", isDirectory: true)
        }
        return directory.appendingPathComponent(hookStoreFilename, isDirectory: false)
    }
}

struct AgentLaunchCommandSnapshot: Codable, Equatable, Sendable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
}

struct CmuxVaultConfigDefinition: Codable, Hashable, Sendable {
    var agents: [CmuxVaultAgentRegistration]

    init(agents: [CmuxVaultAgentRegistration] = []) {
        self.agents = agents
    }
}

struct CmuxVaultAgentRegistration: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var detect: CmuxVaultAgentDetectRule
    var sessionIdSource: CmuxVaultAgentSessionIDSource
    var resumeCommand: String
    var cwd: CmuxVaultAgentCWDPolicy
    var sessionDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case detect
        case sessionIdSource
        case resumeCommand
        case cwd
        case sessionDirectory
    }

    init(
        id: String,
        name: String,
        detect: CmuxVaultAgentDetectRule,
        sessionIdSource: CmuxVaultAgentSessionIDSource,
        resumeCommand: String,
        cwd: CmuxVaultAgentCWDPolicy = .preserve,
        sessionDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detect = detect
        self.sessionIdSource = sessionIdSource
        self.resumeCommand = resumeCommand
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Vault agent id must contain only letters, numbers, dots, underscores, and hyphens"
            )
        }

        let rawName = try container.decode(String.self, forKey: .name)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Vault agent name must not be blank"
            )
        }

        let rawResumeCommand = try container.decode(String.self, forKey: .resumeCommand)
        let resumeCommand = rawResumeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resumeCommand.isEmpty,
              resumeCommand.contains("{{sessionId}}") || resumeCommand.contains("{{sessionPath}}") else {
            throw DecodingError.dataCorruptedError(
                forKey: .resumeCommand,
                in: container,
                debugDescription: "Vault agent resumeCommand must include {{sessionId}}"
            )
        }

        self.id = id
        self.name = name
        self.detect = try container.decodeIfPresent(CmuxVaultAgentDetectRule.self, forKey: .detect) ?? .init()
        self.sessionIdSource = try container.decode(CmuxVaultAgentSessionIDSource.self, forKey: .sessionIdSource)
        self.resumeCommand = resumeCommand
        self.cwd = try container.decodeIfPresent(CmuxVaultAgentCWDPolicy.self, forKey: .cwd) ?? .preserve

        if let rawSessionDirectory = try container.decodeIfPresent(String.self, forKey: .sessionDirectory) {
            let sessionDirectory = rawSessionDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sessionDirectory = sessionDirectory.isEmpty ? nil : sessionDirectory
        } else {
            self.sessionDirectory = nil
        }
    }

    static func isValidID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    var defaultExecutable: String {
        if let processName = detect.processName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return processName
        }
        return id
    }

    static var builtInPi: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "pi",
            name: "Pi",
            detect: CmuxVaultAgentDetectRule(
                processName: "pi",
                argvContains: ["pi"]
            ),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.pi/agent/sessions"
        )
    }
}

struct CmuxVaultAgentDetectRule: Codable, Hashable, Sendable {
    var processName: String?
    var argvContains: [String]

    private enum CodingKeys: String, CodingKey {
        case processName
        case argvContains
    }

    init(processName: String? = nil, argvContains: [String] = []) {
        self.processName = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.argvContains = argvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processName = try container.decodeIfPresent(String.self, forKey: .processName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.processName = processName?.isEmpty == true ? nil : processName
        self.argvContains = try Self.decodeOneOrManyStrings(forKey: .argvContains, in: container)
    }

    private static func decodeOneOrManyStrings(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return [value]
        }
        return []
    }
}

enum CmuxVaultAgentSessionIDSource: Codable, Hashable, Sendable {
    case argvOption(String)
    case piSessionFile

    private enum CodingKeys: String, CodingKey {
        case type
        case argvOption
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "piSessionFile", "pi-session-file":
                self = .piSessionFile
            default:
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "sessionIdSource must not be blank"
                        )
                    )
                }
                self = .argvOption(trimmed)
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !option.isEmpty {
            self = .argvOption(option)
            return
        }

        let type = try container.decode(String.self, forKey: .type)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "piSessionFile", "pi-session-file":
            self = .piSessionFile
        case "argvOption", "argv-option":
            let option = try container.decode(String.self, forKey: .argvOption)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "argvOption must not be blank"
                )
            }
            self = .argvOption(option)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown sessionIdSource type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .argvOption(let option):
            try container.encode("argvOption", forKey: .type)
            try container.encode(option, forKey: .argvOption)
        case .piSessionFile:
            try container.encode("piSessionFile", forKey: .type)
        }
    }
}

enum CmuxVaultAgentCWDPolicy: String, Codable, Hashable, Sendable {
    case preserve
    case ignore

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "preserve": self = .preserve
        case "ignore", "none": self = .ignore
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown Vault cwd policy '\(value)'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CmuxVaultAgentRegistry: Sendable {
    var registrations: [CmuxVaultAgentRegistration]

    init(registrations: [CmuxVaultAgentRegistration]) {
        var ordered: [CmuxVaultAgentRegistration] = []
        var indexesByID: [String: Int] = [:]
        for registration in registrations {
            if let existingIndex = indexesByID[registration.id] {
                ordered[existingIndex] = registration
            } else {
                indexesByID[registration.id] = ordered.count
                ordered.append(registration)
            }
        }
        self.registrations = ordered
    }

    func registration(id: String) -> CmuxVaultAgentRegistration? {
        registrations.first { $0.id == id }
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        var registrations = [CmuxVaultAgentRegistration.builtInPi]
        for path in configPaths(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager
        ) {
            guard let config = decodeConfig(at: path, fileManager: fileManager) else { continue }
            registrations.append(contentsOf: config.vault?.agents ?? [])
        }
        return CmuxVaultAgentRegistry(registrations: registrations)
    }

    private static func configPaths(
        homeDirectory: String,
        workingDirectory: String?,
        environment: [String: String],
        fileManager: FileManager
    ) -> [String] {
        var paths: [String] = []
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        let globalPath = (standardizedHome as NSString).appendingPathComponent(".config/cmux/cmux.json")
        paths.append(globalPath)

        if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            if let local = findLocalConfig(startingAt: cwd, fileManager: fileManager) {
                paths.append(local)
            }
        } else if let pwd = environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pwd.isEmpty,
                  let local = findLocalConfig(startingAt: pwd, fileManager: fileManager) {
            paths.append(local)
        }

        var seen = Set<String>()
        return paths.filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }

    private static func findLocalConfig(startingAt path: String, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        let start: String
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            start = path
        } else {
            start = (path as NSString).deletingLastPathComponent
        }

        var current = (start as NSString).standardizingPath
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            for candidate in candidates where fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
    }

    private static func decodeConfig(at path: String, fileManager: FileManager) -> CmuxConfigFile? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            return nil
        }
        return try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
    }
}
