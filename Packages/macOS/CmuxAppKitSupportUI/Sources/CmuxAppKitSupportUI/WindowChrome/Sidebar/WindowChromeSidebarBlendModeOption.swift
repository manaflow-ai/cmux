public import AppKit

/// Sidebar material blend mode values persisted in `sidebarBlendMode`.
public enum WindowChromeSidebarBlendModeOption: String, CaseIterable, Identifiable, Sendable {
    /// Blend the material behind the window.
    case behindWindow

    /// Blend the material within the window.
    case withinWindow

    /// Stable identity equal to the persisted raw value.
    public var id: String { rawValue }

    /// Localized display title.
    public var title: String {
        switch self {
        case .behindWindow: return String(localized: "settings.blendMode.behindWindow", defaultValue: "Behind Window")
        case .withinWindow: return String(localized: "settings.blendMode.withinWindow", defaultValue: "Within Window")
        }
    }

    /// AppKit blending mode for this option.
    public var mode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}
