import Foundation

/// A short name for the config profile an agent launched under, derived from
/// the replay-safe launch environment cmux already captures
/// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Shown in the compact status glyph's
/// tooltip so sessions under different accounts can be told apart.
///
/// - `~/.claude-outlook` -> "outlook"
/// - `~/.subrouter/codex/claude-proxy/<scope>` -> "sr proxy" (the pooled
///   account is chosen server side and is not visible here)
/// - the default `~/.claude` / `~/.codex`, or no override -> nil
enum SidebarAgentProfileLabel {
    static let subrouterProxyLabel = "sr proxy"

    static func label(environment: [String: String]?, homeDirectory: String) -> String? {
        guard let environment else { return nil }
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            if let label = label(configDirectory: environment[key], homeDirectory: homeDirectory) {
                return label
            }
        }
        return nil
    }

    static func label(configDirectory raw: String?, homeDirectory: String) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let home = (homeDirectory as NSString).standardizingPath
        let expanded = raw.hasPrefix("~/") ? home + String(raw.dropFirst()) : raw
        let path = (expanded as NSString).standardizingPath
        let defaults = [".claude", ".codex"].map { (home as NSString).appendingPathComponent($0) }
        guard !defaults.contains(path) else { return nil }

        let components = (path as NSString).pathComponents
        if components.contains(".subrouter"), components.contains("claude-proxy") {
            return subrouterProxyLabel
        }
        let last = (path as NSString).lastPathComponent
        var name = last.hasPrefix(".") ? String(last.dropFirst()) : last
        for prefix in ["claude-", "codex-", "claude_", "codex_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.isEmpty ? last : name
    }
}
