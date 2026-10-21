import CmuxNextActions

/// A section of the right sidebar. Files and Find are the file explorer's
/// (they show once a provider registers them, ``RightSidebarSections``).
nonisolated enum RightSidebarMode: String, CaseIterable, Hashable, Sendable {
    case files, find, sessions, feed, dock, machines

    /// The action that shows this section.
    var actionID: ActionID {
        switch self {
        case .files: "switchRightSidebarToFiles"
        case .find: "switchRightSidebarToFind"
        case .sessions: "switchRightSidebarToSessions"
        case .feed: "switchRightSidebarToFeed"
        case .dock: "switchRightSidebarToDock"
        case .machines: "switchRightSidebarToMachines"
        }
    }

    /// The mode bar button's SF Symbol (the action's catalog symbol).
    var symbol: String {
        switch self {
        case .files: "doc.text"
        case .find: "text.magnifyingglass"
        case .sessions: "archivebox"
        case .feed: "dot.radiowaves.left.and.right"
        case .dock: "dock.rectangle"
        case .machines: "cloud"
        }
    }
}
