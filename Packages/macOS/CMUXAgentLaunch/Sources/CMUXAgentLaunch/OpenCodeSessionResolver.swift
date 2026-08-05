import Foundation

/// Resolves OpenCode's SQLite session store from a captured launch environment.
public struct OpenCodeSessionResolver: Sendable {
    /// Kernel-derived path captured from the live OpenCode process. cmux keeps
    /// this as transcript provenance and never replays it into a child process.
    public static let capturedDatabasePathEnvironmentKey =
        "CMUX_OPENCODE_DATABASE_PATH"

    private let defaultHomeDirectory: String

    /// Creates an OpenCode session resolver.
    /// - Parameter defaultHomeDirectory: Fallback home when the captured environment omits `HOME`.
    public init(defaultHomeDirectory: String) {
        self.defaultHomeDirectory = defaultHomeDirectory
    }

    /// Returns the OpenCode database path represented by an environment snapshot.
    ///
    /// A kernel-captured path takes precedence, followed by `OPENCODE_DB`.
    /// Relative overrides resolve under OpenCode's XDG data directory. Without
    /// an override, `XDG_DATA_HOME` takes precedence over `HOME`.
    ///
    /// - Parameter env: Captured source-process environment values.
    /// - Returns: The resolved database path, including `:memory:` when selected.
    public func databasePath(env: [String: String]) -> String {
        if let capturedPath = normalized(env[Self.capturedDatabasePathEnvironmentKey]),
           (capturedPath as NSString).isAbsolutePath {
            return capturedPath
        }
        if let configuredPath = normalized(env["OPENCODE_DB"]) {
            guard configuredPath != ":memory:",
                  !(configuredPath as NSString).isAbsolutePath else {
                return configuredPath
            }
            return (dataDirectory(env: env) as NSString)
                .appendingPathComponent(configuredPath)
        }
        return (dataDirectory(env: env) as NSString)
            .appendingPathComponent("opencode.db")
    }

    private func dataDirectory(env: [String: String]) -> String {
        let dataHome: String
        if let xdgDataHome = normalized(env["XDG_DATA_HOME"]) {
            dataHome = expandedPath(xdgDataHome, env: env)
        } else {
            let home = normalized(env["HOME"]) ?? defaultHomeDirectory
            dataHome = (expandedPath(home, env: env) as NSString)
                .appendingPathComponent(".local/share")
        }
        return (dataHome as NSString).appendingPathComponent("opencode")
    }

    /// Returns an explicit database path only when storage identity was captured.
    /// - Parameter env: Captured source-process environment values.
    /// - Returns: The captured or configured file path, otherwise `nil`.
    public func capturedDatabasePath(env: [String: String]) -> String? {
        if let capturedPath = normalized(env[Self.capturedDatabasePathEnvironmentKey]) {
            guard (capturedPath as NSString).isAbsolutePath else { return nil }
            return capturedPath
        }
        if let configuredPath = normalized(env["OPENCODE_DB"]) {
            return configuredPath == ":memory:" ? nil : databasePath(env: env)
        }
        guard normalized(env["XDG_DATA_HOME"]) != nil
                || normalized(env["HOME"]) != nil else {
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
