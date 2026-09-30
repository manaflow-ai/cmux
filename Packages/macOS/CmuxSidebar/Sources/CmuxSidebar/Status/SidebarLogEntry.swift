public import Foundation

/// One log line shown in the workspace's sidebar log feed.
public struct SidebarLogEntry: Equatable, Sendable {
    /// The log message text.
    public let message: String
    /// Severity level.
    public let level: SidebarLogLevel
    /// Optional source label (e.g. the reporting tool).
    public let source: String?
    /// When the entry was reported.
    public let timestamp: Date

    /// Creates a log entry.
    public init(message: String, level: SidebarLogLevel, source: String?, timestamp: Date) {
        self.message = message
        self.level = level
        self.source = source
        self.timestamp = timestamp
    }
}
