import CMUXAgentLaunch
import Foundation

// MARK: - Agents

struct RegisteredSessionAgent: Hashable, Sendable {
    let id: String
    let name: String?
    let iconAssetName: String?

    init(id: String, name: String? = nil, iconAssetName: String? = nil) {
        self.id = id
        self.name = Self.normalizedOptional(name)
        self.iconAssetName = Self.normalizedOptional(iconAssetName)
    }

    init(registration: CmuxVaultAgentRegistration) {
        self.init(id: registration.id, name: registration.name, iconAssetName: registration.iconAssetName)
    }

    var displayName: String {
        if let name {
            return name
        }
        if id == "pi" {
            return "Pi"
        }
        return id
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum SessionAgent: Identifiable, Codable, Sendable, Hashable {
    case claude
    case codex
    case grok
    case opencode
    case rovodev
    case hermesAgent
    case registered(RegisteredSessionAgent)

    var id: String { rawValue }

    static let builtInCases: [SessionAgent] = [.claude, .codex, .grok, .opencode, .rovodev, .hermesAgent]

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        case "hermes-agent": self = .hermesAgent
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .registered(RegisteredSessionAgent(id: value))
        }
    }

    var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .hermesAgent: return "hermes-agent"
        case .registered(let agent): return agent.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.id) {
            let id = try container.decode(String.self, forKey: .id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            let iconAssetName = try container.decodeIfPresent(String.self, forKey: .iconAssetName)
            let hasRegisteredMetadata = name != nil || iconAssetName != nil
            if let builtIn = SessionAgent(rawValue: id),
               (!CmuxVaultAgentRegistration.isValidID(id) || SessionAgent.builtInCases.contains(builtIn)),
               !hasRegisteredMetadata {
                self = builtIn
                return
            }
            guard CmuxVaultAgentRegistration.isValidID(id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Invalid session agent '\(id)'"
                )
            }
            self = .registered(RegisteredSessionAgent(
                id: id,
                name: name,
                iconAssetName: iconAssetName
            ))
            return
        }

        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let agent = SessionAgent(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid session agent '\(value)'"
                )
            )
        }
        self = agent
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .registered(let agent):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(agent.id, forKey: .id)
            try container.encodeIfPresent(agent.name, forKey: .name)
            try container.encodeIfPresent(agent.iconAssetName, forKey: .iconAssetName)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

enum OpenCodeDatabaseSnapshot {
    struct Snapshot {
        let databaseURL: URL
        private let directoryURL: URL

        init(databaseURL: URL, directoryURL: URL) {
            self.databaseURL = databaseURL
            self.directoryURL = directoryURL
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private static let sourcePath = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath

    static func make(prefix: String) throws -> Snapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else { return nil }

        let snapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db")
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: snapshotDB.path)
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        do {
            for sidecar in ["-wal", "-shm"] {
                let source = sourcePath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        return Snapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }
}

// MARK: - Session entry

struct PullRequestLink: Hashable, Sendable {
    let number: Int
    let url: String
    let repository: String?
}

/// Agent-specific fields used to build the resume command with appropriate flags.
enum AgentSpecifics: Hashable, Sendable {
    case claude(model: String?, permissionMode: String?, configDirectoryForResume: String?)
    case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
    case grok(model: String?, permissionMode: String?, sandboxMode: String?, grokHome: String?)
    case opencode(providerModel: String?, agentName: String?)
    case rovodev
    case hermesAgent(source: String?, model: String?, hermesHome: String?)
    case registered(CmuxVaultAgentRegistration)
}

enum ClaudeConfigurationRoot {
    nonisolated static func configuredResumeDirectory(
        _ configDir: String,
        fileManager: FileManager = .default
    ) -> String? {
        let preferredConfigDir = ClaudeConfigDirectoryPath.preferredPath(
            configDir,
            fileManager: fileManager
        )
        guard isLikelyConfigured(preferredConfigDir, fileManager: fileManager) else {
            return nil
        }
        return preferredConfigDir
    }

    nonisolated static func isLikelyConfigured(
        _ configDir: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let configPath = ((configDir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(".claude.json")
        guard let data = fileManager.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return hasConfiguredAuthValue(obj["oauthAccount"])
            || hasConfiguredAuthValue(obj["primaryApiKey"])
            || hasConfiguredAuthValue(obj["apiKey"])
    }

    private nonisolated static func hasConfiguredAuthValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else {
            return false
        }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let dictionary = value as? [String: Any] {
            return !dictionary.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        return true
    }
}
