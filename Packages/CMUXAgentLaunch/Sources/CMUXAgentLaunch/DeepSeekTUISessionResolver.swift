import Foundation

public enum DeepSeekTUISessionResolver {
    public static func sessionsRoot(env: [String: String]) -> String {
        if let override = normalized(env["CMUX_DEEPSEEK_TUI_SESSIONS_DIR"]) {
            return expandedPath(override, env: env)
        }
        return (homeDirectory(env: env) as NSString)
            .appendingPathComponent(".deepseek/sessions")
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func homeDirectory(env: [String: String]) -> String {
        normalized(env["HOME"]) ?? NSHomeDirectory()
    }

    private static func expandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return NSString(string: trimmed).expandingTildeInPath
        }
        let home = homeDirectory(env: env)
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }
}
