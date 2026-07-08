#if DEBUG
import Foundation
import SwiftUI

struct SpinnerSpec: Identifiable {
    enum Energy: String {
        case low = "Low"
        case mediumHigh = "Medium–High"
        case high = "High"

        var color: Color {
            switch self {
            case .low: return .green
            case .mediumHigh: return .orange
            case .high: return .red
            }
        }
    }

    let id = UUID()
    let title: String
    let mechanism: String
    let energy: Energy
    let shipping: Bool
    let makeView: () -> AnyView
}
#endif
