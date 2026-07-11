#if os(iOS)
import SwiftUI

enum BubbleStyle {
    case agent
    case user
    case pending
    case streaming

    var foreground: Color {
        switch self {
        case .agent, .pending, .streaming:
            .primary
        case .user:
            .white
        }
    }

    var background: Color {
        switch self {
        case .agent:
            Color(uiColor: .secondarySystemBackground)
        case .user:
            .accentColor
        case .pending:
            Color(uiColor: .tertiarySystemFill)
        case .streaming:
            Color(uiColor: .secondarySystemFill)
        }
    }
}
#endif
