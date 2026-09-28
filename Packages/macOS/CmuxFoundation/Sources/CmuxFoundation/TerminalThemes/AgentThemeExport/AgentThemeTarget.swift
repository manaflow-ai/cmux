public import Foundation

/// An agent TUI that `cmux themes export` can write a theme file for.
public enum AgentThemeTarget: String, CaseIterable, Sendable {
    /// Claude Code: `~/.claude/themes/<slug>.json`, `{ name, base, overrides }`.
    case claude
    /// OpenCode: `~/.config/opencode/themes/<slug>.json`, `{ $schema, defs, theme }`.
    case opencode

    /// Parses a `--to` value, ignoring case. Accepts `claude-code` for Claude.
    /// - Parameter argument: The raw command-line value.
    public init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
        case "claude", "claude-code", "claudecode":
            self = .claude
        case "opencode":
            self = .opencode
        default:
            return nil
        }
    }

    /// The directory the agent loads user themes from.
    ///
    /// Claude Code honors `CLAUDE_CONFIG_DIR`; OpenCode honors `XDG_CONFIG_HOME`.
    /// Both fall back to `HOME`.
    /// - Parameter environment: The process environment.
    /// - Returns: The theme directory, or `nil` when neither the override nor `HOME` is set.
    public func themeDirectory(environment: [String: String]) -> URL? {
        func nonEmpty(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        switch self {
        case .claude:
            if let configDirectory = nonEmpty("CLAUDE_CONFIG_DIR") {
                return URL(fileURLWithPath: configDirectory, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            }
            return nonEmpty("HOME").map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent(".claude/themes", isDirectory: true)
            }
        case .opencode:
            if let configHome = nonEmpty("XDG_CONFIG_HOME") {
                return URL(fileURLWithPath: configHome, isDirectory: true)
                    .appendingPathComponent("opencode/themes", isDirectory: true)
            }
            return nonEmpty("HOME").map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent(".config/opencode/themes", isDirectory: true)
            }
        }
    }
}
