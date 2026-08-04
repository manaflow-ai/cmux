import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case terminal
    case sidebar
    case browser
    case keyboard
    case automation
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            String(localized: "section.general.title", defaultValue: "General")
        case .terminal:
            String(localized: "section.terminal.title", defaultValue: "Terminal")
        case .sidebar:
            String(localized: "section.sidebar.title", defaultValue: "Sidebar")
        case .browser:
            String(localized: "section.browser.title", defaultValue: "Browser")
        case .keyboard:
            String(localized: "section.keyboard.title", defaultValue: "Keyboard")
        case .automation:
            String(localized: "section.automation.title", defaultValue: "Automation")
        case .advanced:
            String(localized: "section.advanced.title", defaultValue: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .sidebar: "sidebar.left"
        case .browser: "globe"
        case .keyboard: "keyboard"
        case .automation: "bolt.horizontal"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    var detail: String {
        switch self {
        case .general:
            String(localized: "section.general.detail", defaultValue: "Language, appearance, updates")
        case .terminal:
            String(localized: "section.terminal.detail", defaultValue: "Font, scrollback, bell")
        case .sidebar:
            String(localized: "section.sidebar.detail", defaultValue: "Layout, badges, metadata")
        case .browser:
            String(localized: "section.browser.detail", defaultValue: "Search, links, history")
        case .keyboard:
            String(localized: "section.keyboard.detail", defaultValue: "Shortcuts and chords")
        case .automation:
            String(localized: "section.automation.detail", defaultValue: "Socket, hooks, ports")
        case .advanced:
            String(localized: "section.advanced.detail", defaultValue: "Diagnostics and reset")
        }
    }

    var searchText: String {
        "\(title) \(detail)"
    }
}
