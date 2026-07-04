public import Foundation

/// Parsed Issue Inbox configuration.
public struct IssueInboxConfig: Equatable, Sendable {
    /// Configured issue sources.
    public var sources: [IssueInboxSourceConfig]
    /// Auto-refresh interval in seconds. V1 parses this but only supports `0`.
    public var autoRefreshSeconds: Int

    /// Creates an Issue Inbox configuration.
    ///
    /// - Parameters:
    ///   - sources: Configured issue sources.
    ///   - autoRefreshSeconds: Auto-refresh interval in seconds.
    public init(
        sources: [IssueInboxSourceConfig] = [],
        autoRefreshSeconds: Int = 0
    ) {
        self.sources = sources
        self.autoRefreshSeconds = autoRefreshSeconds
    }
}
