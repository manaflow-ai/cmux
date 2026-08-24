import Foundation

/// Reads and atomically writes the versioned automation configuration.
///
/// The automation file intentionally lives beside the event log at
/// `~/.cmuxterm/automations.json`: it is easy to diff, copy between machines,
/// and edit without touching the GUI settings file. Callers inject a home URL
/// in tests; no environment variable is consulted for the default location.
final class AutomationConfigStore {
    static let fileName = "automations.json"
    private static let maximumFileBytes: UInt64 = 4 * 1024 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL = AutomationConfigStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    static func defaultFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads the file, treating a missing file as an empty v1 configuration.
    func load() throws -> AutomationConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AutomationConfiguration()
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.uint64Value > Self.maximumFileBytes {
            throw AutomationConfigStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        let configuration = try decoder.decode(AutomationConfiguration.self, from: data)
        guard configuration.version == AutomationConfiguration.currentVersion else {
            throw AutomationConfigStoreError.unsupportedVersion(configuration.version)
        }
        try validate(configuration)
        return configuration
    }

    /// Writes a complete configuration using a temporary sibling and rename.
    func save(_ configuration: AutomationConfiguration) throws {
        guard configuration.version == AutomationConfiguration.currentVersion else {
            throw AutomationConfigStoreError.unsupportedVersion(configuration.version)
        }
        try validate(configuration)
        let data = try encoder.encode(configuration)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    func updateRule(id: String, _ update: (inout AutomationRule) -> Void) throws -> AutomationRule {
        var configuration = try load()
        guard let index = configuration.rules.firstIndex(where: { $0.id == id }) else {
            throw AutomationConfigStoreError.ruleNotFound(id)
        }
        update(&configuration.rules[index])
        try save(configuration)
        return configuration.rules[index]
    }

    private func validate(_ configuration: AutomationConfiguration) throws {
        guard configuration.rules.count <= 512 else {
            throw AutomationConfigStoreError.invalidRule("configuration contains more than 512 rules")
        }
        var ids = Set<String>()
        for rule in configuration.rules {
            guard !rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationConfigStoreError.invalidRule("rule id must not be empty")
            }
            guard rule.id.utf8.count <= 256 else {
                throw AutomationConfigStoreError.invalidRule("rule \(rule.id.prefix(32)) has an id longer than 256 bytes")
            }
            guard ids.insert(rule.id).inserted else {
                throw AutomationConfigStoreError.invalidRule("duplicate rule id: \(rule.id)")
            }
            guard !rule.when.isEmpty else {
                throw AutomationConfigStoreError.invalidRule("rule \(rule.id) must define when.event or when.category")
            }
            guard !rule.actions.isEmpty else {
                throw AutomationConfigStoreError.invalidRule("rule \(rule.id) must define at least one action")
            }
            guard rule.actions.count <= 64 else {
                throw AutomationConfigStoreError.invalidRule("rule \(rule.id) contains more than 64 actions")
            }
            guard rule.predicates.count <= 128 else {
                throw AutomationConfigStoreError.invalidRule("rule \(rule.id) contains too many predicates")
            }
            for action in rule.actions {
                switch action.action.lowercased() {
                case "notify":
                    break
                case "rpc":
                    guard let method = action.string(for: "method"), !method.isEmpty else {
                        throw AutomationConfigStoreError.invalidRule("rule \(rule.id) has an rpc action without method")
                    }
                case "run":
                    guard let command = action.string(for: "command") ?? action.string(for: "cmd"),
                          !command.isEmpty else {
                        throw AutomationConfigStoreError.invalidRule("rule \(rule.id) has a run action without command")
                    }
                case "webhook":
                    guard let rawURL = action.string(for: "url"),
                          let url = URL(string: rawURL),
                          let scheme = url.scheme?.lowercased(),
                          url.host != nil,
                          ["http", "https"].contains(scheme) else {
                        throw AutomationConfigStoreError.invalidRule("rule \(rule.id) has an invalid webhook url")
                    }
                default:
                    throw AutomationConfigStoreError.invalidRule("rule \(rule.id) has unknown action \(action.action)")
                }
            }
        }
    }
}

enum AutomationConfigStoreError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case ruleNotFound(String)
    case invalidRule(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported automation configuration version \(version)"
        case .ruleNotFound(let id):
            return "Automation rule not found: \(id)"
        case .invalidRule(let message):
            return "Invalid automation rule: \(message)"
        case .fileTooLarge:
            return "Automation configuration is larger than 4 MiB"
        }
    }
}
