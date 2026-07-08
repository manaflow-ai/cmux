import Foundation

/// Mode shown in the right sidebar (the panel toggled by Command-Option-B).
nonisolated enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock
    case fleet
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .fleet: return String(localized: "rightSidebar.mode.fleet", defaultValue: "Fleet")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .fleet: return "square.grid.3x1.below.line.grid.1x2"
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
        case .fleet: return nil
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions, .fleet]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}
