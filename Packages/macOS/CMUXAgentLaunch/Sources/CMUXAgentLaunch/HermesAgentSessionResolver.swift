import Foundation

public enum HermesAgentSessionResolver {
    public static func hermesHome(env: [String: String]) -> String {
        if let home = normalized(env["HERMES_HOME"]) {
            return expandedPath(home, env: env)
        }
        let baseHome = normalized(env["HOME"]) ?? NSHomeDirectory()
        return (baseHome as NSString).appendingPathComponent(".hermes")
    }

    public static func configPath(env: [String: String]) -> String {
        (hermesHome(env: env) as NSString).appendingPathComponent("config.yaml")
    }

    public static func stateDBPath(env: [String: String]) -> String {
        (hermesHome(env: env) as NSString).appendingPathComponent("state.db")
    }

    public static func allowlistPath(env: [String: String]) -> String {
        (hermesHome(env: env) as NSString).appendingPathComponent("shell-hooks-allowlist.json")
    }

    public static func expandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return NSString(string: trimmed).expandingTildeInPath
        }
        let home = normalized(env["HOME"]) ?? NSHomeDirectory()
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
