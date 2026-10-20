#if DEBUG
import SwiftUI

enum SpinnerEnergy: String {
    case low = "Low"
    case mediumHigh = "Medium-High"
    case high = "High"

    var color: Color {
        switch self {
        case .low: return .green
        case .mediumHigh: return .orange
        case .high: return .red
        }
    }
}
#endif
