/// How bad one journaled problem is, from least to most severe.
public enum ErrorLevel: String, Sendable, Codable, CaseIterable, Comparable {
    /// Something went wrong but the app carried on (`WARN`, `console.warn`).
    case warning
    /// An operation failed (`ERROR`, `Logger.error`, `console.error`, an uncaught page error).
    case error
    /// A bug the code never expected (`Logger.fault`, a Rust panic, `FATAL`).
    case fault
    /// A process ended: a system crash or hang report.
    case crash

    private var rank: Int {
        switch self {
        case .warning: 0
        case .error: 1
        case .fault: 2
        case .crash: 3
        }
    }

    public static func < (lhs: ErrorLevel, rhs: ErrorLevel) -> Bool { lhs.rank < rhs.rank }
}
