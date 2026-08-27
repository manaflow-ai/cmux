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
    ///   - launchWorkingDirectory: Directory captured with the agent launch,
    ///     used to resolve a relative `CODEX_HOME`.
    ///   - launchVerificationHome: Captured user home used for provider-state
    ///     verification when `CODEX_HOME` was not set.
    ///   - ambientEnvironment: Environment of the process doing the lookup.
    ///   - fallbackHomeDirectory: Home used when no launch or ambient home is
    ///     available; this is primarily a deterministic test seam.
    ///   - preferFallbackHomeDirectory: Whether the explicit fallback root is
    ///     authoritative over ambient process homes after launch metadata has
    ///     been considered. Index loads use this to keep injected home roots
    ///     isolated from the process running the test or app.
    /// - Returns: A tilde-expanded, standardized Codex state directory path.
    public func resolve(
        launchEnvironment: [String: String]? = nil,
        launchWorkingDirectory: String? = nil,
        launchVerificationHome: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackHomeDirectory: String? = nil,
        preferFallbackHomeDirectory: Bool = false
    ) -> String {
        if let launchCodexHome = normalized(launchEnvironment?["CODEX_HOME"]) {
            return standardized(
                launchCodexHome,
                relativeTo: launchWorkingDirectory,
                tildeHome: launchHomeForTildeExpansion(
                    launchEnvironment: launchEnvironment,
                    launchVerificationHome: launchVerificationHome
                )
            )
        }
        if let launchHome = normalized(launchVerificationHome) {
            return codexDirectory(
                forHome: launchHome,
                relativeTo: launchWorkingDirectory,
                tildeHome: launchHome
            )
        }
        if let launchHome = normalized(launchEnvironment?["HOME"]) {
            return codexDirectory(
                forHome: launchHome,
                relativeTo: launchWorkingDirectory,
                tildeHome: launchHome
            )
        }
        if preferFallbackHomeDirectory,
           let fallbackHome = normalized(fallbackHomeDirectory) {
            return codexDirectory(forHome: fallbackHome, tildeHome: fallbackHome)
        }
        if let ambientCodexHome = normalized(ambientEnvironment["CODEX_HOME"]) {
            return standardized(
                ambientCodexHome,
                tildeHome: normalized(ambientEnvironment["HOME"])
            )
        }
        if let ambientHome = normalized(ambientEnvironment["HOME"]) {
            return codexDirectory(forHome: ambientHome, tildeHome: ambientHome)
        }
        let fallbackHome = fallbackHomeDirectory ?? NSHomeDirectory()
        return codexDirectory(forHome: fallbackHome, tildeHome: fallbackHome)
    }

    private func codexDirectory(
        forHome home: String,
        relativeTo base: String? = nil,
        tildeHome: String? = nil
    ) -> String {
        URL(
            fileURLWithPath: expanded(home, relativeTo: base, tildeHome: tildeHome),
            isDirectory: true
        )
        .appendingPathComponent(".codex", isDirectory: true)
        .standardizedFileURL
        .path
    }

    private func standardized(
        _ path: String,
        relativeTo base: String? = nil,
        tildeHome: String? = nil
    ) -> String {
        (expanded(path, relativeTo: base, tildeHome: tildeHome) as NSString).standardizingPath
    }

    private func expanded(
        _ path: String,
        relativeTo base: String? = nil,
        tildeHome: String? = nil
    ) -> String {
        let expandedPath = expandTilde(path, using: tildeHome)
        guard !expandedPath.hasPrefix("/"),
              let base,
              let normalizedBase = normalized(base) else {
            return expandedPath
        }
        return URL(
            fileURLWithPath: expandedPath,
            relativeTo: URL(
                fileURLWithPath: expandTilde(normalizedBase, using: tildeHome),
                isDirectory: true
            )
        ).standardizedFileURL.path
    }

    private func launchHomeForTildeExpansion(
        launchEnvironment: [String: String]?,
        launchVerificationHome: String?
    ) -> String? {
        normalized(launchVerificationHome)
            ?? normalized(launchEnvironment?["HOME"])
    }

    private func expandTilde(_ path: String, using home: String?) -> String {
        guard path == "~" || path.hasPrefix("~/"),
              let home = normalized(home) else {
            return NSString(string: path).expandingTildeInPath
        }
        let expandedHome = NSString(string: home).expandingTildeInPath
        return path == "~"
            ? expandedHome
            : expandedHome + String(path.dropFirst())
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
