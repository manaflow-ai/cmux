import Foundation

/// One entry of this process's unified log, as ``OSLogErrorSource`` reads it.
struct OSLogRecord: Sendable, Equatable {
    /// The entry's level; `messageType` is the name a log store predicate compares.
    enum Level: Sendable, Equatable {
        case debug, info, notice, error, fault

        var messageType: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "default"
            case .error: "error"
            case .fault: "fault"
            }
        }
    }

    var date: Date
    var level: Level
    var subsystem: String
    var category: String
    var message: String
}
