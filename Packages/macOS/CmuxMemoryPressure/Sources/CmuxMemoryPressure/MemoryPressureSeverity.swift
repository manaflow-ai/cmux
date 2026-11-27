/// The three severity levels used by memory-pressure policy.
public enum MemoryPressureSeverity: Int, Comparable, Sendable {
    /// The measured signal is below the warning threshold.
    case normal = 0
    /// The measured signal crossed the warning threshold.
    case warning = 1
    /// The measured signal crossed the critical threshold.
    case critical = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The stable machine-readable name used by diagnostics and logs.
    public var logName: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}
