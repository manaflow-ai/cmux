import Foundation

public enum SettingsNavigationTarget: String, CaseIterable, Identifiable, Sendable {
    case account
    case app
    case terminal
    case sidebarAppearance
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

    public var title: String {
        switch self {
        case .account:
            return String(localized: "settings.section.account", defaultValue: "Account")
        case .app:
            return String(localized: "settings.section.app", defaultValue: "App")
        case .terminal:
            return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .workspaceColors:
            return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .sidebarAppearance:
            return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .betaFeatures:
            return String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        case .automation:
            return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .browser:
            return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport:
            return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey:
            return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .settingsJSON:
            return String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json")
        case .reset:
            return String(localized: "settings.section.reset", defaultValue: "Reset")
        }
    }

    public var symbolName: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .app:
            return "gearshape"
        case .terminal:
            return "terminal"
        case .workspaceColors:
            return "paintpalette"
        case .sidebarAppearance:
            return "sidebar.left"
        case .betaFeatures:
            return "exclamationmark.triangle"
        case .automation:
            return "wand.and.sparkles"
        case .browser:
            return "globe"
        case .browserImport:
            return "square.and.arrow.down"
        case .globalHotkey:
            return "keyboard.badge.ellipsis"
        case .keyboardShortcuts:
            return "keyboard"
        case .settingsJSON:
            return "doc.text"
        case .reset:
            return "arrow.counterclockwise"
        }
    }

    public var searchText: String {
        switch self {
        case .account:
            return "\(title) sign in team sync"
        case .app:
            return "\(title) appearance language workspace notifications menu bar telemetry"
        case .terminal:
            return "\(title) scrollbar auto resume restore reopen relaunch quit sessions agents claude codex opencode rovodev hibernation idle suspend commands approvals prefixes toggle"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .betaFeatures:
            return "\(title) beta experimental unstable feed dock right sidebar"
        case .automation:
            return "\(title) socket integrations hooks ports claude cursor gemini"
        case .browser:
            return "\(title) search engine links history theme"
        case .browserImport:
            return "\(title) browser import data bookmarks history cookies"
        case .globalHotkey:
            return "\(title) system wide shortcut"
        case .keyboardShortcuts:
            return "\(title) keybindings commands chords"
        case .settingsJSON:
            return "\(title) config file preferences editor documentation schema jsonc reload"
        case .reset:
            return "\(title) defaults"
        }
    }
}
