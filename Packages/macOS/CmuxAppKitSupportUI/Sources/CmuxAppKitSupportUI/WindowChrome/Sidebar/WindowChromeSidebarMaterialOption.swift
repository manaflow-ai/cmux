public import AppKit

/// Sidebar material option values persisted in `sidebarMaterial`.
public enum WindowChromeSidebarMaterialOption: String, CaseIterable, Identifiable, Sendable {
    /// No AppKit material.
    case none

    /// Native macOS liquid glass when available.
    case liquidGlass

    /// AppKit sidebar material.
    case sidebar

    /// AppKit HUD window material.
    case hudWindow

    /// AppKit menu material.
    case menu

    /// AppKit popover material.
    case popover

    /// AppKit under-window background material.
    case underWindowBackground

    /// AppKit window background material.
    case windowBackground

    /// AppKit content background material.
    case contentBackground

    /// AppKit full-screen UI material.
    case fullScreenUI

    /// AppKit sheet material.
    case sheet

    /// AppKit header view material.
    case headerView

    /// AppKit tooltip material.
    case toolTip

    /// Stable identity equal to the persisted raw value.
    public var id: String { rawValue }

    /// Localized display title.
    public var title: String {
        switch self {
        case .none: return String(localized: "settings.material.none", defaultValue: "None")
        case .liquidGlass: return String(localized: "settings.material.liquidGlass", defaultValue: "Liquid Glass (macOS 26+)")
        case .sidebar: return String(localized: "settings.material.sidebar", defaultValue: "Sidebar")
        case .hudWindow: return String(localized: "settings.material.hudWindow", defaultValue: "HUD Window")
        case .menu: return String(localized: "settings.material.menu", defaultValue: "Menu")
        case .popover: return String(localized: "settings.material.popover", defaultValue: "Popover")
        case .underWindowBackground: return String(localized: "settings.material.underWindow", defaultValue: "Under Window")
        case .windowBackground: return String(localized: "settings.material.windowBackground", defaultValue: "Window Background")
        case .contentBackground: return String(localized: "settings.material.contentBackground", defaultValue: "Content Background")
        case .fullScreenUI: return String(localized: "settings.material.fullScreenUI", defaultValue: "Full Screen UI")
        case .sheet: return String(localized: "settings.material.sheet", defaultValue: "Sheet")
        case .headerView: return String(localized: "settings.material.headerView", defaultValue: "Header View")
        case .toolTip: return String(localized: "settings.material.toolTip", defaultValue: "Tool Tip")
        }
    }

    /// Whether this option prefers native `NSGlassEffectView`.
    public var usesLiquidGlass: Bool {
        self == .liquidGlass
    }

    /// AppKit material for this option, or `nil` when no material is drawn.
    public var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .liquidGlass: return .underWindowBackground
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .underWindowBackground: return .underWindowBackground
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .fullScreenUI: return .fullScreenUI
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .toolTip: return .toolTip
        }
    }
}
