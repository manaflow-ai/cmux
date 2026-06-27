public import Foundation

/// One unified-log line captured for a mobile diagnostics report.
public struct MobileDiagnosticsOSLogEntry: Sendable, Equatable {
    private static let unavailableSubsystem = "cmux"
    private static let unavailableCategory = "diagnostics.osLogUnavailable"

    /// When the log entry was emitted.
    public var date: Date
    /// The unified-log subsystem.
    public var subsystem: String
    /// The unified-log category.
    public var category: String
    /// The log level name.
    public var level: String
    /// The display-safe log message. The `OSLogStore` reader leaves this blank
    /// so shared reports never include arbitrary unified-log message bodies.
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

    /// Create a display-safe status entry for an unavailable unified-log read.
    ///
    /// - Parameters:
    ///   - date: When the failed read was observed.
    ///   - message: Localized status text safe to render in a shared report.
    /// - Returns: A status entry recognized by ``MobileDiagnosticsReportBuilder``.
    public static func unavailableStatus(date: Date, message: String) -> MobileDiagnosticsOSLogEntry {
        MobileDiagnosticsOSLogEntry(
            date: date,
            subsystem: unavailableSubsystem,
            category: unavailableCategory,
            level: "error",
            message: message
        )
    }

    var isUnavailableStatus: Bool {
        subsystem == Self.unavailableSubsystem && category == Self.unavailableCategory
    }
}
