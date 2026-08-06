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
           isAbsoluteFilePath(capturedPath) {
            return capturedPath
        }
        if let configuredPath = normalized(env["OPENCODE_DB"]) {
            guard configuredPath != ":memory:",
                  !isAbsoluteFilePath(configuredPath) else {
                return configuredPath
            }
            return (dataDirectory(env: env) as NSString)
                .appendingPathComponent(configuredPath)
        }
        return (dataDirectory(env: env) as NSString)
            .appendingPathComponent("opencode.db")
    }

    private func dataDirectory(env: [String: String]) -> String {
        let home = absoluteHomeDirectory(env: env)
        let dataHome: String
        if let xdgDataHome = normalized(env["XDG_DATA_HOME"]),
           let absoluteXDGDataHome = absolutePath(xdgDataHome, home: home) {
            dataHome = absoluteXDGDataHome
        } else {
            dataHome = (home as NSString).appendingPathComponent(".local/share")
        }
        return (dataHome as NSString).appendingPathComponent("opencode")
    }

    /// Returns an explicit database path only when storage identity was captured.
    /// - Parameter env: Captured source-process environment values.
    /// - Returns: The captured or configured file path, otherwise `nil`.
    public func capturedDatabasePath(env: [String: String]) -> String? {
        if let capturedPath = normalized(env[Self.capturedDatabasePathEnvironmentKey]) {
            if isAbsoluteFilePath(capturedPath) {
                return capturedPath
            }
        }
        if let configuredPath = normalized(env["OPENCODE_DB"]) {
            guard configuredPath != ":memory:" else { return nil }
            if isAbsoluteFilePath(configuredPath) {
                return configuredPath
            }
            guard hasStableCapturedDataRoot(env: env) else { return nil }
            return databasePath(env: env)
        }
        guard hasStableCapturedDataRoot(env: env) else { return nil }
        return databasePath(env: env)
    }

    private func hasStableCapturedDataRoot(env: [String: String]) -> Bool {
        let hasAbsoluteHome = normalized(env["HOME"])
            .map(isAbsoluteFilePath) == true
        guard let xdgDataHome = normalized(env["XDG_DATA_HOME"]) else {
            return hasAbsoluteHome
        }
        if xdgDataHome == "~" || xdgDataHome.hasPrefix("~/") {
            return hasAbsoluteHome
        }
        return isAbsoluteFilePath(xdgDataHome)
    }

    private func absoluteHomeDirectory(env: [String: String]) -> String {
        if let home = normalized(env["HOME"]),
           isAbsoluteFilePath(home) {
            return (home as NSString).standardizingPath
        }
        if isAbsoluteFilePath(defaultHomeDirectory) {
            return (defaultHomeDirectory as NSString).standardizingPath
        }
        return "/"
    }

    private func absolutePath(_ path: String, home: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            guard trimmed != "~" else { return home }
            return ((home as NSString)
                .appendingPathComponent(String(trimmed.dropFirst(2))) as NSString)
                .standardizingPath
        }
        if isAbsoluteFilePath(trimmed) {
            return (trimmed as NSString).standardizingPath
        }
        return nil
    }

    private func isAbsoluteFilePath(_ path: String) -> Bool {
        path.hasPrefix("/") && (path as NSString).isAbsolutePath
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
