import Foundation

/// Top-level navigation targets for the settings window.
///
/// The cmux app exposes a fixed set of section panes. Each section gets
/// its own SwiftUI view in `Sections/`; the sidebar lists them in
/// declaration order, the search index filters across all of them.
///
/// Adding a section means: add a case here, add its title and icon in
/// the `SettingsSectionID` extension below, and add a view file in
/// `Sections/`.
public enum SettingsSectionID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case account
    /// Appearance, terminal font, interface scale, sidebar background, and workspace color settings.
    case appearance
    case app
    case terminal
    case textBox
    /// Sleepy Mode screensaver + keep-awake lock.
    case sleepyMode
    /// Mobile pairing and sync settings.
    case mobile
    case sidebarAppearance
    /// User/agent-authored custom sidebars: enable gate and renderer choice.
    case customSidebars
    case betaFeatures
    case automation
    case browser
    case browserImport
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    public var id: Self { self }

    /// User-facing section title shown in the sidebar.
    public var title: String {
        switch self {
        case .account: return "Account"
        case .appearance: return String(localized: "settings.section.appearance", defaultValue: "Appearance")
        case .app: return "App"
        case .terminal: return "Terminal"
        case .textBox: return String(localized: "settings.section.textBox", defaultValue: "TextBox (Beta)")
        case .sleepyMode: return String(localized: "settings.section.sleepyMode", defaultValue: "Sleepy Mode")
        case .mobile: return String(localized: "settings.section.mobile", defaultValue: "Mobile")
        case .sidebarAppearance: return "Sidebar"
        case .customSidebars: return String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars")
        case .betaFeatures: return "Beta Features"
        case .automation: return "Automation"
        case .browser: return "Browser"
        case .browserImport: return "Import Browser Data"
        case .globalHotkey: return "Global Hotkey"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .workspaceColors: return "Workspace Colors"
        case .settingsJSON: return "cmux.json"
        case .reset: return "Reset"
        }
    }

    /// SF Symbol shown alongside the title in the sidebar.
    public var symbolName: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .app: return "gearshape"
        case .terminal: return "terminal"
        case .textBox: return "textformat"
        case .sleepyMode: return "moon.zzz"
        case .mobile: return "iphone"
        case .sidebarAppearance: return "sidebar.left"
        case .customSidebars: return "sidebar.squares.left"
        case .betaFeatures: return "exclamationmark.triangle"
        case .automation: return "wand.and.sparkles"
        case .browser: return "globe"
        case .browserImport: return "square.and.arrow.down"
        case .globalHotkey: return "keyboard.badge.ellipsis"
        case .keyboardShortcuts: return "keyboard"
        case .workspaceColors: return "paintpalette"
        case .settingsJSON: return "doc.text"
        case .reset: return "arrow.counterclockwise"
        }
    }

    /// Space-separated keywords used by the settings search index. Each
    /// section can advertise additional terms here so users find sections
    /// by capability rather than only by title.
    public var searchKeywords: String {
        switch self {
        case .account: return "sign in team sync user profile"
        case .appearance: return "appearance theme font family size terminal sidebar workspace colors ui scale light dark"
        case .app: return "language workspace notifications menu bar telemetry"
        case .terminal: return "scrollbar copy on select agent resume hibernation"
        case .textBox: return "textbox text box rich input prompt default new terminal workspace split tab focus show beta"
        case .sleepyMode: return "sleepy mode screensaver caffeinate keep awake lock touch id battery wifi clock mascot theme glow pixel"
        case .mobile: return "ios iphone ipad mobile pairing local network sync"
        case .sidebarAppearance: return "sidebar details branches material terminal background"
        case .customSidebars: return "custom sidebars vibe swift json interpreted renderer in-process remote worker isolated"
        case .betaFeatures: return "beta experimental unstable feed dock right sidebar"
        case .automation: return "socket integrations hooks ports claude cursor gemini naming auto naming workspace tabs"
        case .browser: return "search engine links history theme"
        case .browserImport: return "browser import bookmarks history cookies"
        case .globalHotkey: return "system wide shortcut"
        case .keyboardShortcuts: return "keybindings commands chords"
        case .workspaceColors: return "palette tabs indicator"
        case .settingsJSON: return "config file preferences editor schema jsonc reload"
        case .reset: return "defaults reset"
        }
    }
}
