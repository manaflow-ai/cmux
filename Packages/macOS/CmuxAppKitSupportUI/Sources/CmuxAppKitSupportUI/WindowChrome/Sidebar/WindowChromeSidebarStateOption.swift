public import AppKit

/// Sidebar material state values persisted in `sidebarState`.
public enum WindowChromeSidebarStateOption: String, CaseIterable, Identifiable, Sendable {
    /// Force the material active.
    case active

    /// Force the material inactive.
    case inactive

    /// Follow the containing window's active state.
    case followWindow

    /// Stable identity equal to the persisted raw value.
    public var id: String { rawValue }

    /// Localized display title.
    public var title: String {
        switch self {
        case .active: return String(localized: "settings.state.active", defaultValue: "Active")
        case .inactive: return String(localized: "settings.state.inactive", defaultValue: "Inactive")
        case .followWindow: return String(localized: "settings.state.followWindow", defaultValue: "Follow Window")
        }
    }

    /// AppKit visual-effect state for this option.
    public var state: NSVisualEffectView.State {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .followWindow: return .followsWindowActiveState
        }
    }
}
