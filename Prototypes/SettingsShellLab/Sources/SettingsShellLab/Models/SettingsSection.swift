import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
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
            return String(localized: "section.general.title", defaultValue: "General")
        case .terminal:
            return String(localized: "section.terminal.title", defaultValue: "Terminal")
        case .sidebar:
            return String(localized: "section.sidebar.title", defaultValue: "Sidebar")
        case .browser:
            return String(localized: "section.browser.title", defaultValue: "Browser")
        case .keyboard:
            return String(localized: "section.keyboard.title", defaultValue: "Keyboard")
        case .automation:
            return String(localized: "section.automation.title", defaultValue: "Automation")
        case .advanced:
            return String(localized: "section.advanced.title", defaultValue: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .terminal:
            return "terminal"
        case .sidebar:
            return "sidebar.left"
        case .browser:
            return "globe"
        case .keyboard:
            return "keyboard"
        case .automation:
            return "bolt.horizontal"
        case .advanced:
            return "wrench.and.screwdriver"
        }
    }

    var detail: String {
        switch self {
        case .general:
            return String(localized: "section.general.detail", defaultValue: "Language, appearance, updates")
        case .terminal:
            return String(localized: "section.terminal.detail", defaultValue: "Font, scrollback, bell")
        case .sidebar:
            return String(localized: "section.sidebar.detail", defaultValue: "Layout, badges, metadata")
        case .browser:
            return String(localized: "section.browser.detail", defaultValue: "Search, links, history")
        case .keyboard:
            return String(localized: "section.keyboard.detail", defaultValue: "Shortcuts and chords")
        case .automation:
            return String(localized: "section.automation.detail", defaultValue: "Socket, hooks, ports")
        case .advanced:
            return String(localized: "section.advanced.detail", defaultValue: "Diagnostics and reset")
        }
    }

    var searchText: String {
        "\(title) \(detail)"
    }
}
