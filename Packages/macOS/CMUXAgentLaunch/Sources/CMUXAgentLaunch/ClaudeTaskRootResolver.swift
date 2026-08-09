import Foundation

/// Resolves Claude Code's task-store root from one hook process environment.
public struct ClaudeTaskRootResolver {
    private let environment: [String: String]
    private let homeDirectoryURL: URL

    /// Creates a resolver for a specific hook process environment.
    ///
    /// - Parameters:
    ///   - environment: The Claude hook process environment.
    ///   - homeDirectoryURL: The fallback hook-user home directory.
    public init(environment: [String: String], homeDirectoryURL: URL) {
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
    }

    /// Resolves the directory containing Claude's per-session task stores.
    ///
    /// `CLAUDE_CONFIG_DIR` wins when configured; otherwise tasks are read from
    /// `$HOME/.claude/tasks`. An absent or empty hook `HOME` falls back to the
    /// supplied home directory.
    ///
    /// - Returns: The configured Claude tasks directory.
    public func resolve() -> URL {
        configRootURL().appendingPathComponent("tasks", isDirectory: true)
            .canonicalClaudeTaskStoreDirectoryURL
    }

    /// Resolves the team-config sibling from the logical profile root.
    ///
    /// The `tasks` leaf may itself be a symlink to another volume. Team configs
    /// remain relative to the configured profile, so they must be canonicalized
    /// independently instead of derived from the resolved tasks URL.
    ///
    /// - Returns: The configured Claude teams directory.
    public func resolveTeamsRoot() -> URL {
        configRootURL().appendingPathComponent("teams", isDirectory: true)
            .canonicalClaudeTaskStoreDirectoryURL
    }

    private func configRootURL() -> URL {
        let configuredDirectory = nonEmptyEnvironmentValue(environment["CLAUDE_CONFIG_DIR"])
        let environmentHome = nonEmptyEnvironmentValue(environment["HOME"]).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let hookHomeURL = environmentHome ?? homeDirectoryURL
        let configURL: URL
        if let configuredDirectory {
            if configuredDirectory == "~" {
                configURL = hookHomeURL
            } else if configuredDirectory.hasPrefix("~/") {
                configURL = hookHomeURL.appendingPathComponent(
                    String(configuredDirectory.dropFirst(2)),
                    isDirectory: true
                )
            } else {
                configURL = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
            }
        } else {
            configURL = hookHomeURL.appendingPathComponent(".claude", isDirectory: true)
        }
        return configURL
    }

    private func nonEmptyEnvironmentValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
