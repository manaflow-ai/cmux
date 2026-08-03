#if DEBUG
import AppKit

enum SpinnerEnergy: String {
    case low = "Low"
    case mediumHigh = "Medium-High"
    case high = "High"

    var color: NSColor {
        switch self {
        case .low: .systemGreen
        case .mediumHigh: .systemOrange
        case .high: .systemRed
        }
    }
}
#endif
