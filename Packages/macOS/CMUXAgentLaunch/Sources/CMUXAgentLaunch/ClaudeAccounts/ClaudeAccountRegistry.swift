import Foundation

/// The user's registered Claude accounts, built from `agents.claudeAccounts` declarations.
public struct ClaudeAccountRegistry: Equatable, Sendable {
    /// Name reserved for the default (`~/.claude`) account.
    public static let defaultAccountName = "default"

    /// Accounts in display order. Always contains exactly one default account.
    public let accounts: [ClaudeAccount]

    private let homeDirectory: String

    /// Builds the registry from declarations in reading order.
    ///
    /// Invalid declarations are dropped. A repeated name replaces the earlier entry in place (last
    /// wins, first position); a config directory already used by another entry is dropped (first
    /// wins). A directory that normalizes to `<home>/.claude` is the default account and keeps the
    /// declared name. When none does, an implicit "default" account is inserted first. The name
    /// "default" is reserved for the default directory.
    public init(declarations: [ClaudeAccountDeclaration], homeDirectory: String) {
        let home = (homeDirectory as NSString).standardizingPath
        self.homeDirectory = home
        let defaultDir = home + "/.claude"

        var entries: [(name: String, dir: String)] = []
        for declaration in declarations {
            guard Self.isValidName(declaration.name),
                  let dir = Self.normalize(declaration.configDir, homeDirectory: home) else { continue }
            if declaration.name == Self.defaultAccountName, dir != defaultDir { continue }
            if let index = entries.firstIndex(where: { $0.name == declaration.name }) {
                let clash = entries.indices.contains { $0 != index && entries[$0].dir == dir }
                if !clash { entries[index].dir = dir }
            } else if !entries.contains(where: { $0.dir == dir }) {
                entries.append((declaration.name, dir))
            }
        }

        var accounts = entries.map { entry in
            ClaudeAccount(
                name: entry.name,
                configDirectory: entry.dir == defaultDir ? nil : entry.dir,
                isRegistered: true
            )
        }
        if !accounts.contains(where: { $0.isDefault }) {
            accounts.insert(
                ClaudeAccount(name: Self.defaultAccountName, configDirectory: nil, isRegistered: true),
                at: 0
            )
        }
        self.accounts = accounts
    }

    /// Decodes `agents.claudeAccounts` from comment-stripped `cmux.json` bytes. Malformed input
    /// yields no declarations.
    public static func declarations(sanitizedConfigJSON: Data) -> [ClaudeAccountDeclaration] {
        guard !sanitizedConfigJSON.isEmpty,
              let file = try? JSONDecoder().decode(ConfigFile.self, from: sanitizedConfigJSON) else {
            return []
        }
        return file.agents?.claudeAccounts ?? []
    }

    /// Loads declarations from the user-level then project config files; later files override
    /// earlier ones by account name.
    public static func load(
        homeDirectory: String,
        workingDirectory: String?,
        fileManager: FileManager = .default,
        sanitize: (Data) throws -> Data
    ) -> ClaudeAccountRegistry {
        var merged: [ClaudeAccountDeclaration] = []
        let paths = AgentExternalLauncherRegistry.configPaths(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        for path in paths {
            guard let data = fileManager.contents(atPath: path), !data.isEmpty,
                  let sanitized = try? sanitize(data) else { continue }
            merged.append(contentsOf: declarations(sanitizedConfigJSON: sanitized))
        }
        return ClaudeAccountRegistry(declarations: merged, homeDirectory: homeDirectory)
    }

    /// The registered account with this name.
    public func account(named name: String) -> ClaudeAccount? {
        accounts.first { $0.name == name }
    }

    /// The account a launch environment resolves to. An unset, empty or `<home>/.claude`
    /// `CLAUDE_CONFIG_DIR` is the default account; an unknown directory is an unregistered account
    /// named after the directory.
    public func account(forEnvironment environment: [String: String]?) -> ClaudeAccount {
        let defaultAccount = accounts.first { $0.isDefault }
            ?? ClaudeAccount(name: Self.defaultAccountName, configDirectory: nil, isRegistered: true)
        guard let raw = environment?["CLAUDE_CONFIG_DIR"],
              let dir = Self.normalize(raw, homeDirectory: homeDirectory),
              dir != homeDirectory + "/.claude" else {
            return defaultAccount
        }
        if let match = accounts.first(where: { $0.configDirectory == dir }) { return match }
        return ClaudeAccount(name: Self.unregisteredName(forDirectory: dir), configDirectory: dir, isRegistered: false)
    }

    private static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// Expands `~/` against `homeDirectory` (not the process home), then normalizes with
    /// `ClaudeConfigDirectoryPath.preferredPath`. Returns `nil` for anything that is neither
    /// absolute nor `~/`-relative.
    private static func normalize(_ raw: String, homeDirectory home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed.hasPrefix("~/") {
            expanded = home + String(trimmed.dropFirst())
        } else if trimmed.hasPrefix("/") {
            expanded = trimmed
        } else {
            return nil
        }
        var path = ClaudeConfigDirectoryPath.preferredPath(expanded, homeDirectory: home)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Same basename rule as the sidebar profile label: drop a leading ".", then a
    /// "claude-"/"claude_" prefix.
    private static func unregisteredName(forDirectory dir: String) -> String {
        let last = (dir as NSString).lastPathComponent
        var name = last.hasPrefix(".") ? String(last.dropFirst()) : last
        for prefix in ["claude-", "claude_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.isEmpty ? last : name
    }

    private struct ConfigFile: Decodable {
        let agents: AgentsSection?

        struct AgentsSection: Decodable {
            let claudeAccounts: [ClaudeAccountDeclaration]?
        }
    }
}
