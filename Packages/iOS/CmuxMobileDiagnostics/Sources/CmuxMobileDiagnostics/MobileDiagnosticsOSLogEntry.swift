public import Foundation

/// One unified-log line captured for a mobile diagnostics report.
public struct MobileDiagnosticsOSLogEntry: Sendable, Equatable {
    /// When the log entry was emitted.
    public var date: Date
    /// The unified-log subsystem.
    public var subsystem: String
    /// The unified-log category.
    public var category: String
    /// The log level name.
    public var level: String
    /// The composed log message.
    public var message: String

    /// Create a unified-log entry value.
    ///
    /// - Parameters:
    ///   - date: When the log entry was emitted.
    ///   - subsystem: The unified-log subsystem.
    ///   - category: The unified-log category.
    ///   - level: The log level name.
    ///   - message: The composed log message.
    public init(
        date: Date,
        subsystem: String,
        category: String,
        level: String,
        message: String
    ) {
        self.date = date
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
    }
}
