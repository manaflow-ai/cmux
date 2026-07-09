public import Foundation

/// One persisted workspace log line inside a session snapshot.
///
/// A pure leaf value carrying the log `message`, its `level` (the raw value of
/// the live log level), an optional `source` label, and the `timestamp` the
/// line was recorded (`timeIntervalSince1970`). The on-disk wire format is
/// owned by the app's `SessionTerminalPanelSnapshot`, which carries an array of
/// these values; encoding stays byte-identical to the legacy app-target
/// definition.
public struct SessionLogEntrySnapshot: Codable, Sendable {
    /// The logged message text.
    public var message: String
    /// The raw value of the live log level.
    public var level: String
    /// Optional source label for the line.
    public var source: String?
    /// When the line was recorded, as `timeIntervalSince1970`.
    public var timestamp: TimeInterval

    /// Creates a persisted log entry.
    public init(
        message: String,
        level: String,
        source: String?,
        timestamp: TimeInterval
    ) {
        self.message = message
        self.level = level
        self.source = source
        self.timestamp = timestamp
    }
}
