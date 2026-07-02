import Foundation
import OSLog

struct CmuxVaultConfigDefinition: Codable, Hashable, Sendable {
    var agents: [CmuxVaultAgentRegistration]

    init(agents: [CmuxVaultAgentRegistration] = []) {
        self.agents = agents
    }
}

struct CmuxVaultAgentRegistration: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var iconAssetName: String?
    var detect: CmuxVaultAgentDetectRule
    var sessionIdSource: CmuxVaultAgentSessionIDSource
    var resumeCommand: String
    /// Optional template for forking (branching) a session into a new copy.
    /// Omit it for agents that do not have a fork verb.
    var forkCommand: String?
    var cwd: CmuxVaultAgentCWDPolicy
    var sessionDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName, detect, sessionIdSource, resumeCommand, forkCommand, cwd, sessionDirectory
    }

    init(
        id: String,
        name: String,
        iconAssetName: String? = nil,
        detect: CmuxVaultAgentDetectRule,
        sessionIdSource: CmuxVaultAgentSessionIDSource,
        resumeCommand: String,
        forkCommand: String? = nil,
        cwd: CmuxVaultAgentCWDPolicy = .preserve,
        sessionDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconAssetName = Self.normalizedOptional(iconAssetName)
        self.detect = detect
        self.sessionIdSource = sessionIdSource
        self.resumeCommand = resumeCommand
        self.forkCommand = Self.normalizedOptional(forkCommand)
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidID(id),
              !Self.isReservedID(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Vault agent id must contain only letters, numbers, dots, underscores, and hyphens"
            )
        }

        let name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Vault agent name must not be blank"
            )
        }

        let resumeCommand = try container.decode(String.self, forKey: .resumeCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resumeCommand.isEmpty,
              resumeCommand.contains("{{sessionId}}") || resumeCommand.contains("{{sessionPath}}") else {
            throw DecodingError.dataCorruptedError(
                forKey: .resumeCommand,
                in: container,
                debugDescription: "Vault agent resumeCommand must include {{sessionId}} or {{sessionPath}}"
            )
        }

        self.id = id
        self.name = name
        self.iconAssetName = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .iconAssetName))
        self.detect = try container.decodeIfPresent(CmuxVaultAgentDetectRule.self, forKey: .detect) ?? .init()
        self.sessionIdSource = try container.decode(CmuxVaultAgentSessionIDSource.self, forKey: .sessionIdSource)
        self.resumeCommand = resumeCommand
        if let forkCommand = try container.decodeIfPresent(String.self, forKey: .forkCommand)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !forkCommand.isEmpty {
            guard forkCommand.contains("{{sessionId}}") || forkCommand.contains("{{sessionPath}}") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .forkCommand,
                    in: container,
                    debugDescription: "Vault agent forkCommand must include {{sessionId}} or {{sessionPath}}"
                )
            }
            self.forkCommand = forkCommand
        } else {
            self.forkCommand = nil
        }
        self.cwd = try container.decodeIfPresent(CmuxVaultAgentCWDPolicy.self, forKey: .cwd) ?? .preserve
        let directory = try container.decodeIfPresent(String.self, forKey: .sessionDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionDirectory = directory?.isEmpty == true ? nil : directory
    }

    static func isValidID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isReservedID(_ value: String) -> Bool {
        RestorableAgentKind.allCases.contains { $0.rawValue == value }
    }

    var defaultExecutable: String {
        if let processName = detect.processName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return processName
        }
        if let processName = detect.processNames.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return processName
        }
        return id
    }

    static var builtInPi: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "pi",
            name: "Pi",
            iconAssetName: "AgentIcons/Pi",
            detect: CmuxVaultAgentDetectRule(processName: "pi", argvContains: ["pi"]),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork",
            cwd: .preserve,
            sessionDirectory: "~/.pi/agent/sessions"
        )
    }

    static var builtInOmp: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "omp",
            name: "OMP",
            detect: CmuxVaultAgentDetectRule(
                processName: "omp",
                alternateArgvContains: ["@oh-my-pi/pi-coding-agent"]
            ),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork",
            cwd: .preserve,
            sessionDirectory: "~/.omp/agent/sessions"
        )
    }

    static var builtInAntigravity: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "antigravity",
            name: "Antigravity",
            iconAssetName: "AgentIcons/Antigravity",
            detect: CmuxVaultAgentDetectRule(processNames: ["agy", "antigravity"]),
            sessionIdSource: .argvOption("--conversation"),
            resumeCommand: "{{executable}} --conversation {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.gemini/antigravity-cli"
        )
    }

    static var builtInGrok: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "grok",
            name: "Grok",
            detect: CmuxVaultAgentDetectRule(processNames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"]),
            sessionIdSource: .grokSessionDirectory,
            resumeCommand: "{{executable}} -r {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.grok/sessions"
        )
    }

    /// Hermes (the `hermes` CLI agent). Its id is the reserved `hermes-agent` kind so a single
    /// identity flows through the ``SessionAgent/hermesAgent`` browser entry, the `hermes-agent`
    /// `AgentLaunchSanitizer` argv policy, and the env policy that keeps `HERMES_HOME`. The session
    /// id lives in `~/.hermes/state.db` and cannot be forced into argv, so it uses ``stateDB``;
    /// resume replays the captured launch flags through the shared `hermes-agent` policy (see
    /// `AgentResumeCommandBuilder`), which the `resumeCommand` template below can only approximate.
    static var builtInHermes: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "hermes-agent",
            name: "Hermes Agent",
            iconAssetName: "AgentIcons/HermesAgent",
            detect: CmuxVaultAgentDetectRule(processNames: ["hermes", "hermes-agent"]),
            sessionIdSource: .stateDB,
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: nil
        )
    }

    /// Ids of the built-in Vault registrations seeded by ``CmuxVaultAgentRegistry/load``. Process
    /// detection prefers a user/project-config registration over a built-in when both detectors match
    /// the same process, so a user's own agent is never shadowed by a built-in — including the
    /// reserved-id ``builtInHermes``, which config cannot override by id.
    static let builtInRegistrationIDs: Set<String> = [
        builtInPi.id,
        builtInOmp.id,
        builtInAntigravity.id,
        builtInGrok.id,
        builtInHermes.id,
    ]
}

struct CmuxVaultAgentDetectRule: Codable, Hashable, Sendable {
    var processName: String?
    var processNames: [String]
    var argvContains: [String]
    var alternateArgvContains: [String]

    private enum CodingKeys: String, CodingKey {
        case processName, processNames, argvContains, alternateArgvContains
    }

    init(
        processName: String? = nil,
        processNames: [String] = [],
        argvContains: [String] = [],
        alternateArgvContains: [String] = []
    ) {
        let name = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processName = name?.isEmpty == true ? nil : name
        self.processNames = processNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.argvContains = argvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alternateArgvContains = alternateArgvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .processName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        processName = name?.isEmpty == true ? nil : name
        processNames = try Self.decodeOneOrManyStrings(forKey: .processNames, in: container)
        argvContains = try Self.decodeOneOrManyStrings(forKey: .argvContains, in: container)
        alternateArgvContains = try Self.decodeOneOrManyStrings(forKey: .alternateArgvContains, in: container)
    }

    private static func decodeOneOrManyStrings(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
    case grokSessionDirectory
    /// Resolve the session id from Hermes's `~/.hermes/state.db` (SQLite), scoped to the process
    /// working directory. Hermes mints its own id at startup and rejects `--resume <unknown-id>`,
    /// so the id can neither be forced into argv (``argvOption``) nor read from a per-session JSONL
    /// file (``piSessionFile``); it can only be read back from `state.db` after launch.
    case stateDB

    private enum CodingKeys: String, CodingKey {
        case type, argvOption
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "piSessionFile", "pi-session-file":
                self = .piSessionFile
            case "grokSessionDirectory", "grok-session-directory":
                self = .grokSessionDirectory
            case "stateDB", "state-db":
                self = .stateDB
            default:
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "sessionIdSource must not be blank")
                    )
                }
                self = .argvOption(trimmed)
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type).trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "piSessionFile", "pi-session-file":
            if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !option.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "piSessionFile must not include argvOption"
                )
            }
            self = .piSessionFile
        case "grokSessionDirectory", "grok-session-directory":
            if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !option.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "grokSessionDirectory must not include argvOption"
                )
            }
            self = .grokSessionDirectory
        case "stateDB", "state-db":
            if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !option.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "stateDB must not include argvOption"
                )
            }
            self = .stateDB
        case "argvOption", "argv-option":
            let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let option, !option.isEmpty else {
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
        case .grokSessionDirectory:
            try container.encode("grokSessionDirectory", forKey: .type)
        case .stateDB:
            try container.encode("stateDB", forKey: .type)
        }
    }
}

enum CmuxVaultAgentCWDPolicy: String, Codable, Hashable, Sendable {
    case preserve
    case ignore

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "preserve": self = .preserve
        case "ignore", "none": self = .ignore
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown Vault cwd policy '\(value)'")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CmuxVaultAgentRegistry: Sendable {
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "VaultAgentRegistry")

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

    func mergingProjectConfig(
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty,
              let path = Self.findLocalConfig(startingAt: workingDirectory, fileManager: fileManager),
              let config = Self.decodeConfig(at: path, fileManager: fileManager),
              let agents = config.vault?.agents,
              !agents.isEmpty else {
            return self
        }
        return CmuxVaultAgentRegistry(registrations: registrations + agents)
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        var registrations = [
            CmuxVaultAgentRegistration.builtInPi,
            CmuxVaultAgentRegistration.builtInOmp,
            CmuxVaultAgentRegistration.builtInAntigravity,
            CmuxVaultAgentRegistration.builtInGrok,
            CmuxVaultAgentRegistration.builtInHermes,
        ]
        for path in configPaths(homeDirectory: homeDirectory, workingDirectory: workingDirectory, environment: environment, fileManager: fileManager) {
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
        let home = (homeDirectory as NSString).standardizingPath
        var paths = [(home as NSString).appendingPathComponent(".config/cmux/cmux.json")]
        let startingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startingDirectory, !startingDirectory.isEmpty,
           let local = findLocalConfig(startingAt: startingDirectory, fileManager: fileManager) {
            paths.append(local)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }

    private static func findLocalConfig(startingAt path: String, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        let start = fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent
        var current = (start as NSString).standardizingPath
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString).appendingPathComponent("cmux.json"),
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
        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            return try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        } catch {
            logger.fault(
                "Failed to decode config at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
