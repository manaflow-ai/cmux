import AppKit

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case gitGraph = "git-graph"
    case herd
    case find
    case sessions
    case feed
    case dock
    case machines
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .gitGraph: return String(localized: "rightSidebar.mode.gitGraph", defaultValue: "Git Graph")
        case .herd: return String(localized: "herd.title", defaultValue: "Herd")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .machines: return String(localized: "rightSidebar.mode.machines", defaultValue: "Cloud")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }


    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .gitGraph: return "arrow.triangle.branch"
        case .herd: return "point.3.connected.trianglepath.dotted"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .machines: return "cloud"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .gitGraph, .herd: return nil
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        case .machines: return .switchRightSidebarToMachines
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .gitGraph, .herd, .find, .sessions, .machines]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}
