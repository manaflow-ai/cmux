import CmuxFoundation
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
                debugDescription: "Vault agent id must contain only letters, numbers, dots, underscores, and hyphens and must not exceed 128 UTF-8 bytes"
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
        CmuxAgentSessionRegistry.isSafeProviderIdentifier(value)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isReservedID(_ value: String) -> Bool {
        let caseFolded = value.lowercased()
        if RestorableAgentKind.registryOwnedRawValues.contains(caseFolded) {
            return value != caseFolded
        }
        return RestorableAgentKind.allCases.contains {
            $0.rawValue.caseInsensitiveCompare(value) == .orderedSame
        }
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
            forkCommand: "{{executable}} --fork {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.pi/agent/sessions"
        )
    }

    static var builtInOmp: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "omp",
            name: "OMP",
            iconAssetName: "AgentIcons/Pi",
            detect: CmuxVaultAgentDetectRule(
                processName: "omp",
                alternateArgvContains: ["@oh-my-pi/pi-coding-agent"]
            ),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.omp/agent/sessions"
        )
    }

    var migratedPersistedBuiltInRegistration: CmuxVaultAgentRegistration {
        if matchesPersistedBuiltInHistory(current: Self.builtInPi) {
            return Self.builtInPi
        }
        if matchesPersistedBuiltInOmpHistory() {
            return Self.builtInOmp
        }
        if matchesPersistedBuiltInWithoutFork(current: Self.builtInGrok) {
            return Self.builtInGrok
        }
        if matchesPersistedBuiltInWithoutFork(current: Self.builtInCampfire) {
            return Self.builtInCampfire
        }
        return self
    }

    private func matchesPersistedBuiltInHistory(current: CmuxVaultAgentRegistration) -> Bool {
        let legacyForkCommand = "{{executable}} --session {{sessionId}} --fork"
        guard iconAssetName == nil || iconAssetName == current.iconAssetName,
              forkCommand == legacyForkCommand else {
            return false
        }
        var candidate = self
        candidate.iconAssetName = current.iconAssetName
        candidate.forkCommand = current.forkCommand
        return candidate == current
    }

    private func matchesPersistedBuiltInOmpHistory() -> Bool {
        let current = Self.builtInOmp
        let legacyResumeCommand = "{{executable}} --session {{sessionId}}"
        let legacyForkCommands: Set<String> = [
            "{{executable}} --fork {{sessionId}}",
            "{{executable}} --session {{sessionId}} --fork",
        ]
        let hasKnownForkCommand = forkCommand.map(legacyForkCommands.contains) ?? true
        guard resumeCommand == legacyResumeCommand,
              hasKnownForkCommand,
              iconAssetName == nil || iconAssetName == current.iconAssetName else {
            return false
        }
        var candidate = self
        candidate.iconAssetName = current.iconAssetName
        candidate.resumeCommand = current.resumeCommand
        candidate.forkCommand = current.forkCommand
        return candidate == current
    }

    private func matchesPersistedBuiltInWithoutFork(current: CmuxVaultAgentRegistration) -> Bool {
        guard forkCommand == nil else { return false }
        var candidate = self
        candidate.forkCommand = current.forkCommand
        return candidate == current
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
            forkCommand: "{{executable}} --resume {{sessionId}} --fork-session",
            cwd: .preserve,
            sessionDirectory: "~/.grok/sessions"
        )
    }
}

struct CmuxVaultAgentDetectRule: Codable, Hashable, Sendable {
    var processName: String?
    var processNames: [String]
    var argvContains: [String]
    var alternateProcessNames: [String]
    var alternateArgvContains: [String]
    var alternateArgvContainsAny: [String]

    private enum CodingKeys: String, CodingKey {
        case processName, processNames, argvContains, alternateProcessNames, alternateArgvContains, alternateArgvContainsAny
    }

    init(
        processName: String? = nil,
        processNames: [String] = [],
        argvContains: [String] = [],
        alternateProcessNames: [String] = [],
        alternateArgvContains: [String] = [],
        alternateArgvContainsAny: [String] = []
    ) {
        let name = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processName = name?.isEmpty == true ? nil : name
        self.processNames = processNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.argvContains = argvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alternateProcessNames = alternateProcessNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alternateArgvContains = alternateArgvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alternateArgvContainsAny = alternateArgvContainsAny
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
        alternateProcessNames = try Self.decodeOneOrManyStrings(forKey: .alternateProcessNames, in: container)
        alternateArgvContains = try Self.decodeOneOrManyStrings(forKey: .alternateArgvContains, in: container)
        alternateArgvContainsAny = try Self.decodeOneOrManyStrings(forKey: .alternateArgvContainsAny, in: container)
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
    private static let maximumConfigBytes = 1_024 * 1_024
    private static let maximumConfigAncestorCount = 64
    private static let maximumDynamicRegistrationCount =
        CmuxAgentSessionRegistry.maximumProviderEnumerationCount
    private static let builtInRegistrationIDs: Set<String> = [
        "pi", "omp", "campfire", "antigravity", "grok",
    ]

    var registrations: [CmuxVaultAgentRegistration]
    private var detectionIndexesByExecutableName: [String: [Int]]
    private var fallbackDetectionIndexes: [Int]

    struct ProjectConfigCache {
        private let base: CmuxVaultAgentRegistry
        private var registryByDirectory: [String: CmuxVaultAgentRegistry] = [:]
        private(set) var directoryProbeCount = 0
        private(set) var configDecodeCount = 0

        init(base: CmuxVaultAgentRegistry) {
            self.base = base
        }

        mutating func registry(
            forWorkingDirectory workingDirectory: String?,
            fileManager: FileManager
        ) -> CmuxVaultAgentRegistry {
            guard let workingDirectory = workingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !workingDirectory.isEmpty else {
                return base
            }
            var isDirectory: ObjCBool = false
            let start = fileManager.fileExists(
                atPath: workingDirectory,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
                ? workingDirectory
                : (workingDirectory as NSString).deletingLastPathComponent
            var current = (start as NSString).standardizingPath
            var visited: [String] = []
            visited.reserveCapacity(CmuxVaultAgentRegistry.maximumConfigAncestorCount)
            for _ in 0..<CmuxVaultAgentRegistry.maximumConfigAncestorCount {
                if let cached = registryByDirectory[current] {
                    for directory in visited { registryByDirectory[directory] = cached }
                    return cached
                }
                directoryProbeCount += 1
                visited.append(current)
                let candidates = [
                    ((current as NSString).appendingPathComponent(".cmux") as NSString)
                        .appendingPathComponent("cmux.json"),
                    (current as NSString).appendingPathComponent("cmux.json"),
                ]
                if let path = candidates.first(where: {
                    fileManager.fileExists(atPath: $0)
                }) {
                    configDecodeCount += 1
                    let resolved = base.mergingProjectConfig(at: path, fileManager: fileManager)
                    for directory in visited { registryByDirectory[directory] = resolved }
                    return resolved
                }
                let parent = (current as NSString).deletingLastPathComponent
                guard parent != current else { break }
                current = parent
            }
            for directory in visited { registryByDirectory[directory] = base }
            return base
        }
    }

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

        var exactIDsByCaseFold: [String: Set<String>] = [:]
        for registration in ordered {
            exactIDsByCaseFold[registration.id.lowercased(), default: []]
                .insert(registration.id)
        }
        let conflictingCaseFolds = Set(exactIDsByCaseFold.compactMap { key, exactIDs in
            exactIDs.count > 1 ? key : nil
        })
        for caseFold in conflictingCaseFolds.sorted() {
            let exactIDs = exactIDsByCaseFold[caseFold, default: []].sorted()
            Self.logger.fault(
                "Ignoring Vault registrations with case-colliding ids: \(exactIDs.joined(separator: ", "), privacy: .public)"
            )
        }
        let filtered = ordered.filter {
            !conflictingCaseFolds.contains($0.id.lowercased())
        }
        var indexesByExecutableName: [String: [Int]] = [:]
        var fallbackIndexes: [Int] = []
        for (index, registration) in filtered.enumerated() {
            var requiresFallback = registration.detect.needsUnindexedDetectionFallback
            for processName in registration.detect.detectionIndexProcessNames {
                guard let key = Self.detectionIndexKey(processName) else {
                    requiresFallback = true
                    continue
                }
                indexesByExecutableName[key, default: []].append(index)
            }
            if requiresFallback {
                guard fallbackIndexes.count < Self.maximumDynamicRegistrationCount else {
                    continue
                }
                fallbackIndexes.append(index)
            }
        }
        if filtered.filter({ $0.detect.needsUnindexedDetectionFallback }).count
            > fallbackIndexes.count {
            Self.logger.fault(
                "Vault argv-only detection exceeded the bounded fallback catalog"
            )
        }
        self.registrations = filtered
        detectionIndexesByExecutableName = indexesByExecutableName
        fallbackDetectionIndexes = fallbackIndexes
    }

    func registration(id: String) -> CmuxVaultAgentRegistration? {
        registrations.first { $0.id == id }
    }

    func matchingRegistration(
        for process: VaultObservedAgentProcess
    ) -> CmuxVaultAgentRegistration? {
        detectionCandidateIndexes(for: process).lazy
            .map { registrations[$0] }
            .first { $0.detect.matches(process) }
    }

    func detectionCandidateCount(for process: VaultObservedAgentProcess) -> Int {
        detectionCandidateIndexes(for: process).count
    }

    func mergingProjectConfig(
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty,
              let path = Self.findLocalConfig(startingAt: workingDirectory, fileManager: fileManager) else {
            return self
        }
        return mergingProjectConfig(at: path, fileManager: fileManager)
    }

    private func mergingProjectConfig(
        at path: String,
        fileManager: FileManager
    ) -> CmuxVaultAgentRegistry {
        guard let config = Self.decodeConfig(at: path, fileManager: fileManager),
              let agents = config.vault?.agents,
              !agents.isEmpty,
              Self.dynamicRegistrationIDs(in: registrations)
                .union(Self.dynamicRegistrationIDs(in: agents)).count
                <= Self.maximumDynamicRegistrationCount else {
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
            CmuxVaultAgentRegistration.builtInCampfire,
            CmuxVaultAgentRegistration.builtInAntigravity,
            CmuxVaultAgentRegistration.builtInGrok,
        ]
        var dynamicRegistrationIDs = Set<String>()
        for path in configPaths(homeDirectory: homeDirectory, workingDirectory: workingDirectory, environment: environment, fileManager: fileManager) {
            guard let config = decodeConfig(at: path, fileManager: fileManager) else { continue }
            let agents = config.vault?.agents ?? []
            let candidateIDs = dynamicRegistrationIDs.union(
                Self.dynamicRegistrationIDs(in: agents)
            )
            guard candidateIDs.count <= maximumDynamicRegistrationCount else {
                logger.fault(
                    "Ignoring Vault config whose merged dynamic catalog exceeds \(maximumDynamicRegistrationCount) registrations: \(path, privacy: .public)"
                )
                continue
            }
            dynamicRegistrationIDs = candidateIDs
            registrations.append(contentsOf: agents)
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
        for _ in 0..<maximumConfigAncestorCount {
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
        return nil
    }

    private static func decodeConfig(at path: String, fileManager: FileManager) -> CmuxConfigFile? {
        guard fileManager.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            guard let data = try handle.read(upToCount: maximumConfigBytes + 1),
                  !data.isEmpty,
                  data.count <= maximumConfigBytes else {
                return nil
            }
            let sanitized = try JSONCParser.preprocess(data: data)
            let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
            guard (config.vault?.agents.count ?? 0) <= maximumDynamicRegistrationCount else {
                return nil
            }
            return config
        } catch {
            logger.fault(
                "Failed to decode config at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func detectionCandidateIndexes(
        for process: VaultObservedAgentProcess
    ) -> [Int] {
        var indexes = Set(fallbackDetectionIndexes)
        for basename in process.executableBasenames {
            guard let key = Self.detectionIndexKey(basename) else { continue }
            indexes.formUnion(detectionIndexesByExecutableName[key] ?? [])
        }
        return indexes.sorted()
    }

    private static func detectionIndexKey(_ value: String) -> String? {
        let basename = (value as NSString).lastPathComponent
        guard !basename.isEmpty,
              basename.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return nil
        }
        return basename.lowercased()
    }

    private static func dynamicRegistrationIDs(
        in registrations: [CmuxVaultAgentRegistration]
    ) -> Set<String> {
        Set(registrations.compactMap {
            builtInRegistrationIDs.contains($0.id) ? nil : $0.id
        })
    }
}
