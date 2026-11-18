public import AppKit
public import CmuxNextDesignTokens

/// The material behind a floating pane's background, as a Debug Settings choice
/// (``FloatingPaneTunables/material``): none, or one of the system's materials. It blurs what is under the pane.
public nonisolated enum FloatingPaneMaterial: String, Sendable, CaseIterable, TunableChoice {
    case none
    case hudWindow
    case popover
    case menu
    case sidebar
    case headerView
    case sheet
    case titlebar
    case selection
    case windowBackground
    case contentBackground
    case underWindowBackground
    case underPageBackground
    case fullScreenUI

    public var tunableTitle: String {
        switch self {
        case .none: "None"
        case .hudWindow: "HUD window"
        case .popover: "Popover"
        case .menu: "Menu"
        case .sidebar: "Sidebar"
        case .headerView: "Header"
        case .sheet: "Sheet"
        case .titlebar: "Titlebar"
        case .selection: "Selection"
        case .windowBackground: "Window background"
        case .contentBackground: "Content background"
        case .underWindowBackground: "Under window background"
        case .underPageBackground: "Under page background"
        case .fullScreenUI: "Full screen UI"
        }
    }

    /// The system's material; nil for none.
    public var system: NSVisualEffectView.Material? {
        switch self {
        case .none: nil
        case .hudWindow: .hudWindow
        case .popover: .popover
        case .menu: .menu
        case .sidebar: .sidebar
        case .headerView: .headerView
        case .sheet: .sheet
        case .titlebar: .titlebar
        case .selection: .selection
        case .windowBackground: .windowBackground
        case .contentBackground: .contentBackground
        case .underWindowBackground: .underWindowBackground
        case .underPageBackground: .underPageBackground
        case .fullScreenUI: .fullScreenUI
        }
    }
}
