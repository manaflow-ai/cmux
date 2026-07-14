import Foundation

extension SettingsNavigationTarget {
    var searchText: String {
        switch self {
        case .account:
            return "\(title) sign in team sync"
        case .app:
            return "\(title) appearance language workspace notifications menu bar telemetry default terminal"
        case .terminal:
            return "\(title) scrollbar auto resume restore reopen relaunch quit sessions agents claude codex opencode rovodev hibernation idle suspend commands approvals prefixes toggle"
        case .textBox:
            return "\(title) textbox text box rich input prompt beta new terminal workspace split tab focus height"
        case .sleepyMode:
            return "\(title) sleepy mode screensaver caffeinate keep awake lock touch id battery wifi clock mascot theme glow pixel"
        case .mobile:
            return "\(title) ios iphone ipad mobile pairing local network sync"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .customSidebars:
            return "\(title) custom sidebars vibe swift json interpreted renderer in-process remote worker isolated"
        case .betaFeatures:
            return "\(title) beta experimental unstable feed dock right sidebar"
        case .automation:
            return "\(title) socket integrations hooks ports claude cursor gemini kiro naming auto naming workspace tabs"
        case .computerUse:
            return "\(title) \(String(localized: "settings.search.keywords.computerUse", defaultValue: "computer use accessibility screen recording permissions cursor mcp agents menu bar onboarding"))"
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
