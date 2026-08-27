import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

extension MobileTodoStatus {
    var systemImage: String {
        switch self {
        case .todo: "circle"
        case .working: "circle.dotted"
        case .needsAttention: "exclamationmark.circle.fill"
        case .review: "eye.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .todo:
            L10n.string("mobile.todo.status.todo", defaultValue: "Todo")
        case .working:
            L10n.string("mobile.todo.status.working", defaultValue: "Working")
        case .needsAttention:
            L10n.string("mobile.todo.status.needsAttention", defaultValue: "Needs Attention")
        case .review:
            L10n.string("mobile.todo.status.review", defaultValue: "Review")
        case .done:
            L10n.string("mobile.todo.status.done", defaultValue: "Done")
        }
    }

    /// Lane accents matching the Mac sidebar's status glyph palette.
    var tint: Color {
        switch self {
        case .todo: .secondary
        case .working: .accentColor
        // Loudest lane: full-strength attention accent between orange and red.
        case .needsAttention: Color(red: 1.0, green: 0.42, blue: 0.2)
        case .review: .green
        // Muted gray-green so finished lanes read as settled, not celebratory.
        case .done: Color(red: 0.45, green: 0.62, blue: 0.5)
        }
    }
}
