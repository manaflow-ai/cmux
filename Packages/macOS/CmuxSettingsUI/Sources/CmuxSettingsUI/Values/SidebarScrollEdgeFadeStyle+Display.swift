import CmuxSettings
import Foundation

/// UI-facing labels for ``SidebarScrollEdgeFadeStyle``.
extension SidebarScrollEdgeFadeStyle {
    var displayName: String {
        switch self {
        case .full:
            return String(localized: "sidebarScrollEdgeFadeStyle.full.name", defaultValue: "Full")
        case .subtle:
            return String(localized: "sidebarScrollEdgeFadeStyle.subtle.name", defaultValue: "Subtle")
        case .off:
            return String(localized: "sidebarScrollEdgeFadeStyle.off.name", defaultValue: "Off")
        }
    }

    var rowDescription: String {
        switch self {
        case .full:
            return String(localized: "sidebarScrollEdgeFadeStyle.full.description", defaultValue: "Use the current top and bottom fade over the tab list.")
        case .subtle:
            return String(localized: "sidebarScrollEdgeFadeStyle.subtle.description", defaultValue: "Use a shorter, lighter fade at the top and bottom of the tab list.")
        case .off:
            return String(localized: "sidebarScrollEdgeFadeStyle.off.description", defaultValue: "Disable the tab-list fade at both scroll edges.")
        }
    }
}
