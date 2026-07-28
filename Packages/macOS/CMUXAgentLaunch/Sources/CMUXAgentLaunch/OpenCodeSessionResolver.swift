import Foundation

/// Resolves OpenCode's SQLite session store from a captured launch environment.
public struct OpenCodeSessionResolver: Sendable {
    private let defaultHomeDirectory: String

    /// Creates an OpenCode session resolver.
    /// - Parameter defaultHomeDirectory: Fallback home when the captured environment omits `HOME`.
    public init(defaultHomeDirectory: String) {
        self.defaultHomeDirectory = defaultHomeDirectory
    }

    /// Returns the OpenCode database path represented by an environment snapshot.
    ///
    /// `XDG_DATA_HOME` takes precedence over `HOME`; without either captured value,
    /// the current process home supplies OpenCode's standard `.local/share` root.
    ///
    /// - Parameter env: Captured source-process environment values.
    /// - Returns: The resolved `opencode.db` path.
    public func databasePath(env: [String: String]) -> String {
        let dataHome: String
        if let xdgDataHome = normalized(env["XDG_DATA_HOME"]) {
            dataHome = expandedPath(xdgDataHome, env: env)
        } else {
            let home = normalized(env["HOME"]) ?? defaultHomeDirectory
            dataHome = (expandedPath(home, env: env) as NSString)
                .appendingPathComponent(".local/share")
        }
        return (dataHome as NSString).appendingPathComponent("opencode/opencode.db")
    }

    /// Returns an explicit database path only when storage identity was captured.
    /// - Parameter env: Captured source-process environment values.
    /// - Returns: A database path for captured `XDG_DATA_HOME` or `HOME`, otherwise `nil`.
    public func capturedDatabasePath(env: [String: String]) -> String? {
        guard normalized(env["XDG_DATA_HOME"]) != nil || normalized(env["HOME"]) != nil else {
            return nil
        }
        return databasePath(env: env)
    }

    private func expandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return NSString(string: trimmed).expandingTildeInPath
        }
        let home = normalized(env["HOME"]) ?? defaultHomeDirectory
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
