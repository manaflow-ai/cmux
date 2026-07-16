import AppKit
import SwiftUI

enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }

    var color: Color {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return Color(nsColor: .secondaryLabelColor)
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return Color(nsColor: .labelColor)
        case .accent:
            return cmuxAccentColor()
        case .tertiary:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}
