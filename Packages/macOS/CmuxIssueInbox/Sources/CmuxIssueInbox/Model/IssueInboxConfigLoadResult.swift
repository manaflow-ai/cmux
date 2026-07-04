public import Foundation

/// Result of loading Issue Inbox configuration from a source.
public struct IssueInboxConfigLoadResult: Sendable {
    /// Parsed configuration.
    public var config: IssueInboxConfig
    /// Non-fatal warnings collected while parsing.
    public var warnings: [IssueInboxConfigWarning]
    /// Whether the backing config file existed.
    public var fileExists: Bool
    /// Config file URL shown by setup UI.
    public var configURL: URL

    /// Creates a config load result.
    ///
    /// - Parameters:
    ///   - config: Parsed configuration.
    ///   - warnings: Non-fatal warnings collected while parsing.
    ///   - fileExists: Whether the backing config file existed.
    ///   - configURL: Config file URL shown by setup UI.
    public init(
        config: IssueInboxConfig,
        warnings: [IssueInboxConfigWarning],
        fileExists: Bool,
        configURL: URL
    ) {
        self.config = config
        self.warnings = warnings
        self.fileExists = fileExists
        self.configURL = configURL
    }
}
