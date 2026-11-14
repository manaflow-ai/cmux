import Foundation

/// One Claude Code account: a named `CLAUDE_CONFIG_DIR`, or the default `~/.claude` account.
public struct ClaudeAccount: Equatable, Sendable, Codable {
    /// The name menus and the CLI show.
    public let name: String
    /// Absolute, standardized config directory with no trailing slash. `nil` is the default
    /// account, which is represented by the absence of `CLAUDE_CONFIG_DIR`.
    public let configDirectory: String?
    /// Whether the user declared this account (or it is the implicit default).
    public let isRegistered: Bool

    public init(name: String, configDirectory: String?, isRegistered: Bool) {
        self.name = name
        self.configDirectory = configDirectory
        self.isRegistered = isRegistered
    }

    /// Whether this is the default (`~/.claude`) account.
    public var isDefault: Bool { configDirectory == nil }

    /// The directory that identifies this account when tracking exhaustion.
    public func exhaustionKey(homeDirectory: String) -> String {
        configDirectory ?? ((homeDirectory as NSString).standardizingPath + "/.claude")
    }
}

/// An `agents.claudeAccounts` entry as written in `cmux.json`.
public struct ClaudeAccountDeclaration: Decodable, Equatable, Sendable {
    public let name: String
    public let configDir: String

    public init(name: String, configDir: String) {
        self.name = name
        self.configDir = configDir
    }
}
