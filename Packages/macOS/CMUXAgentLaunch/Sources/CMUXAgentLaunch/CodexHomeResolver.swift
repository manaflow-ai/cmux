import Foundation

/// Resolves the Codex state directory from launch-scoped and ambient homes.
///
/// Launch metadata wins over the current process environment so a restored
/// surface cannot silently switch accounts when `CODEX_HOME` changed after the
/// snapshot was written. Callers that use a synthetic home in tests can pass
/// it as ``fallbackHomeDirectory``.
public struct CodexHomeResolver: Sendable {
    /// Creates a stateless Codex home resolver.
    public init() {}

    /// Resolves the effective `.codex` directory for one launch.
    ///
    /// - Parameters:
    ///   - launchEnvironment: Environment captured with the agent launch.
    ///   - launchVerificationHome: Captured user home used for provider-state
    ///     verification when `CODEX_HOME` was not set.
    ///   - ambientEnvironment: Environment of the process doing the lookup.
    ///   - fallbackHomeDirectory: Home used when no launch or ambient home is
    ///     available; this is primarily a deterministic test seam.
    /// - Returns: A tilde-expanded, standardized Codex state directory path.
    public func resolve(
        launchEnvironment: [String: String]? = nil,
        launchVerificationHome: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackHomeDirectory: String? = nil
    ) -> String {
        if let launchCodexHome = normalized(launchEnvironment?["CODEX_HOME"]) {
            return standardized(launchCodexHome)
        }
        if let launchHome = normalized(launchVerificationHome) {
            return codexDirectory(forHome: launchHome)
        }
        if let launchHome = normalized(launchEnvironment?["HOME"]) {
            return codexDirectory(forHome: launchHome)
        }
        if let ambientCodexHome = normalized(ambientEnvironment["CODEX_HOME"]) {
            return standardized(ambientCodexHome)
        }
        if let ambientHome = normalized(ambientEnvironment["HOME"]) {
            return codexDirectory(forHome: ambientHome)
        }
        return codexDirectory(forHome: fallbackHomeDirectory ?? NSHomeDirectory())
    }

    private func codexDirectory(forHome home: String) -> String {
        URL(
            fileURLWithPath: expanded(home),
            isDirectory: true
        )
        .appendingPathComponent(".codex", isDirectory: true)
        .standardizedFileURL
        .path
    }

    private func standardized(_ path: String) -> String {
        (expanded(path) as NSString).standardizingPath
    }

    private func expanded(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
