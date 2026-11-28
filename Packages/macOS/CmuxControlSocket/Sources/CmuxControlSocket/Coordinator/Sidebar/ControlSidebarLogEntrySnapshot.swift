internal import Foundation

/// A Sendable snapshot of one sidebar log entry for the v1 `list_log` /
/// `sidebar_state` line formatting.
public struct ControlSidebarLogEntrySnapshot: Sendable, Equatable {
    /// The log level raw value (`info`/`progress`/`success`/`warning`/`error`).
    public let levelRawValue: String
    /// The log message.
    public let message: String
    /// The optional source label.
    public let source: String?

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - levelRawValue: The log level raw value.
    ///   - message: The log message.
    ///   - source: The optional source label.
    public init(levelRawValue: String, message: String, source: String?) {
        self.levelRawValue = levelRawValue
        self.message = message
        self.source = source
    }
}
