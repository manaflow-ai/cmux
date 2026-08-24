import Foundation

enum MemoryPressureSeverity: Int, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: MemoryPressureSeverity, rhs: MemoryPressureSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var logName: String {
        switch self {
        case .normal:
            "normal"
        case .warning:
            "warning"
        case .critical:
            "critical"
        }
    }
}
