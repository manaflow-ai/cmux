import Foundation

/// The filesystem locations used by OpenCode, resolved from its documented
/// environment overrides.
public struct OpenCodePaths: Sendable, Equatable {
    /// OpenCode's configuration directory: `OPENCODE_CONFIG_DIR`, then
    /// `$XDG_CONFIG_HOME/opencode`, then `~/.config/opencode`.
    public let configDirectory: URL
    /// OpenCode's session database: `OPENCODE_DB`, then
    /// `$XDG_DATA_HOME/opencode/opencode.db`, then
    /// `~/.local/share/opencode/opencode.db`.
    public let databaseURL: URL

    public init(environment: [String: String]) {
        let home = Self.homeURL(environment: environment)
        if let override = Self.nonEmpty(environment["OPENCODE_CONFIG_DIR"]) {
            configDirectory = Self.expandedURL(override, home: home)
        } else if let xdgConfigHome = Self.nonEmpty(environment["XDG_CONFIG_HOME"]) {
            configDirectory = Self.expandedURL(xdgConfigHome, home: home)
                .appendingPathComponent("opencode", isDirectory: true)
        } else {
            configDirectory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        }
        if let override = Self.nonEmpty(environment["OPENCODE_DB"]) {
            databaseURL = Self.expandedURL(override, home: home)
        } else if let xdgDataHome = Self.nonEmpty(environment["XDG_DATA_HOME"]) {
            databaseURL = Self.expandedURL(xdgDataHome, home: home)
                .appendingPathComponent("opencode/opencode.db", isDirectory: false)
        } else {
            databaseURL = home.appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func expandedURL(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func homeURL(environment: [String: String]) -> URL {
        if let home = nonEmpty(environment["HOME"]) {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
