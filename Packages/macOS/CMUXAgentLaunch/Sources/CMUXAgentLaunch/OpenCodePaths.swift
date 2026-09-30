import Foundation

/// Resolves the filesystem locations used by OpenCode from its documented
/// environment overrides.
public enum OpenCodePaths {
    public static func configDirectory(environment: [String: String]) -> URL {
        let home = homeURL(environment: environment)
        if let override = nonEmpty(environment["OPENCODE_CONFIG_DIR"]) {
            return expandedURL(override, home: home)
        }
        if let xdgConfigHome = nonEmpty(environment["XDG_CONFIG_HOME"]) {
            return expandedURL(xdgConfigHome, home: home)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return home.appendingPathComponent(".config/opencode", isDirectory: true)
    }

    public static func databaseURL(environment: [String: String]) -> URL {
        let home = homeURL(environment: environment)
        if let override = nonEmpty(environment["OPENCODE_DB"]) {
            return expandedURL(override, home: home)
        }
        if let xdgDataHome = nonEmpty(environment["XDG_DATA_HOME"]) {
            return expandedURL(xdgDataHome, home: home)
                .appendingPathComponent("opencode/opencode.db", isDirectory: false)
        }
        return home.appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
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
