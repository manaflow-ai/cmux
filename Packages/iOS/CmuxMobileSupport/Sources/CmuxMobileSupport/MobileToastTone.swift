import SwiftUI

enum MobileToastTone: Equatable, Sendable {
    case information
    case success
    case warning
    case error

    var symbolName: String {
        switch self {
        case .information: "sparkles"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .information: .cyan
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var priority: Int {
        switch self {
        case .information, .success: 0
        case .warning: 1
        case .error: 2
        }
    }
}
