#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

enum BubbleStyle {
    case agent
    case user
    case pending
    case streaming

    func foreground(theme: AgentGUITheme) -> Color {
        switch self {
        case .agent, .user, .pending, .streaming:
            Color(theme.foreground)
        }
    }

    func background(theme: AgentGUITheme) -> Color {
        switch self {
        case .agent:
            .clear
        case .user:
            Color(theme.inputBackground)
        case .pending:
            Color(theme.raisedBackground)
        case .streaming:
            .clear
        }
    }
}

extension Color {
    init(_ color: AgentGUIRGBColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

extension UIColor {
    convenience init(_ color: AgentGUIRGBColor) {
        self.init(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    }
}
#endif
