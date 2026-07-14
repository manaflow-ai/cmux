import Foundation

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
nonisolated enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case pullRequests = "pull-requests"
    case feed
    case dock
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .pullRequests: return String(localized: "rightSidebar.mode.pullRequests", defaultValue: "Pull Request")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var modeBarLabel: String {
        switch self {
        case .pullRequests:
            return String(localized: "rightSidebar.mode.pullRequests.short", defaultValue: "PR")
        default:
            return label
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .pullRequests: return "checklist"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        case .pullRequests, .customSidebar: return nil
        }
    }
}
