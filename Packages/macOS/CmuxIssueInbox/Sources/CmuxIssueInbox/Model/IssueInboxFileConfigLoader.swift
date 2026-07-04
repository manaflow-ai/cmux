public import Foundation

/// Loads Issue Inbox configuration from `~/.config/cmux/issue-inbox.json`.
public struct IssueInboxFileConfigLoader: IssueInboxConfigLoading {
    /// Default config path relative to the user's home directory.
    public static let relativeConfigPath = ".config/cmux/issue-inbox.json"

    private let configURL: URL
    private let homeDirectory: URL

    /// Creates a file-backed config loader.
    ///
    /// - Parameters:
    ///   - configURL: Config file URL. Defaults to `~/.config/cmux/issue-inbox.json`.
    ///   - homeDirectory: Home directory used for tilde expansion.
    public init(
        configURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory
        self.configURL = configURL ?? homeDirectory.appendingPathComponent(Self.relativeConfigPath)
    }

    public func loadIssueInboxConfig() throws -> IssueInboxConfigLoadResult {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return IssueInboxConfigLoadResult(
                config: IssueInboxConfig(),
                warnings: [],
                fileExists: false,
                configURL: configURL
            )
        }
        let data = try Data(contentsOf: configURL)
        let decoded = try IssueInboxConfigDecoder(homeDirectory: homeDirectory).decode(data)
        return IssueInboxConfigLoadResult(
            config: decoded.config,
            warnings: decoded.warnings,
            fileExists: true,
            configURL: configURL
        )
    }
}
