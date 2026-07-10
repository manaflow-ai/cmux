import AppKit
import SwiftUI

enum BrowserDevToolsIconOption: String, CaseIterable, Identifiable {
    case wrenchAndScrewdriver = "wrench.and.screwdriver"
    case wrenchAndScrewdriverFill = "wrench.and.screwdriver.fill"
    case curlyBracesSquare = "curlybraces.square"
    case curlyBraces = "curlybraces"
    case terminalFill = "terminal.fill"
    case terminal = "terminal"
    case hammer = "hammer"
    case hammerCircle = "hammer.circle"
    case ladybug = "ladybug"
    case ladybugFill = "ladybug.fill"
    case scope = "scope"
    case codeChevrons = "chevron.left.slash.chevron.right"
    case gearshape = "gearshape"
    case gearshapeFill = "gearshape.fill"
    case globe = "globe"
    case globeAmericas = "globe.americas.fill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrenchAndScrewdriver: return "Wrench + Screwdriver"
        case .wrenchAndScrewdriverFill: return "Wrench + Screwdriver (Fill)"
        case .curlyBracesSquare: return "Curly Braces"
        case .curlyBraces: return "Curly Braces (Plain)"
        case .terminalFill: return "Terminal (Fill)"
        case .terminal: return "Terminal"
        case .hammer: return "Hammer"
        case .hammerCircle: return "Hammer Circle"
        case .ladybug: return "Bug"
        case .ladybugFill: return "Bug (Fill)"
        case .scope: return "Scope"
        case .codeChevrons: return "Code Chevrons"
        case .gearshape: return "Gear"
        case .gearshapeFill: return "Gear (Fill)"
        case .globe: return "Globe"
        case .globeAmericas: return "Globe Americas (Fill)"
        }
    }
}

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
