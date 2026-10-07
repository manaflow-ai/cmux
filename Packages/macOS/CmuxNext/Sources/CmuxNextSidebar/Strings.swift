import CmuxNextDesign
import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static func tabDropRefusal(_ reason: SidebarTabDropRefusal) -> String {
        switch reason {
        case .otherMachine:
            String(localized: "sidebar.tabDrop.otherMachine", defaultValue: "Tabs stay on their machine.", bundle: .module)
        case .pinnedArea:
            String(localized: "sidebar.tabDrop.pinnedArea", defaultValue: "The pinned area holds no new workspace.", bundle: .module)
        }
    }
    static var back: String { String(localized: "sidebar.footer.back", defaultValue: "Back", bundle: .module) }
    static var dismissCard: String { String(localized: "sidebar.card.dismiss", defaultValue: "Dismiss", bundle: .module) }
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .module) }
    static var rename: String { String(localized: "sidebar.rename", defaultValue: "Rename", bundle: .module) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var moveToGroup: String { String(localized: "sidebar.group.moveTo", defaultValue: "Move to Group", bundle: .module) }
    static var projects: String { String(localized: "sidebar.section.projects", defaultValue: "Projects", bundle: .module) }
    static var pinnedEmpty: String { String(localized: "sidebar.section.pinned.empty", defaultValue: "Drop here to pin", bundle: .module) }
    static var sectionEmpty: String { String(localized: "sidebar.section.empty", defaultValue: "No workspaces", bundle: .module) }
    static var statusConnected: String { String(localized: "sidebar.machine.connected", defaultValue: "Connected", bundle: .module) }
    static var statusConnecting: String { String(localized: "sidebar.machine.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var statusOffline: String { String(localized: "sidebar.machine.offline", defaultValue: "Offline", bundle: .module) }
    static var statusUpdateAvailable: String { String(localized: "sidebar.machine.updateAvailable", defaultValue: "Update available", bundle: .module) }
    static var statusUpdateRequired: String { String(localized: "sidebar.machine.updateRequired", defaultValue: "Update needed", bundle: .module) }
    static var statusInstallRequired: String { String(localized: "sidebar.machine.installRequired", defaultValue: "Install needed", bundle: .module) }
    static var statusInstalling: String { String(localized: "sidebar.machine.installing", defaultValue: "Installing…", bundle: .module) }
    static var statusAuthFailed: String { String(localized: "sidebar.machine.authFailed", defaultValue: "Sign-in failed", bundle: .module) }
    static var statusUnreachable: String { String(localized: "sidebar.machine.unreachable", defaultValue: "Unreachable", bundle: .module) }
    static func unreadCount(_ value: Int) -> String { String(localized: "sidebar.a11y.unread", defaultValue: "\(value) unread", bundle: .module) }
    static func progressPercent(_ value: Int) -> String { String(localized: "sidebar.a11y.progress", defaultValue: "\(value)% done", bundle: .module) }
    static var showTabs: String { String(localized: "sidebar.workspace.showTabs", defaultValue: "Show Tabs", bundle: .module) }
    static var hideTabs: String { String(localized: "sidebar.workspace.hideTabs", defaultValue: "Hide Tabs", bundle: .module) }
    static func tabCount(_ value: Int) -> String { String(localized: "sidebar.a11y.tabCount", defaultValue: "Tabs: \(value)", bundle: .module) }
    static var unreadDot: String { String(localized: "sidebar.a11y.unreadDot", defaultValue: "Unread", bundle: .module) }
    static var muted: String { String(localized: "sidebar.a11y.muted", defaultValue: "Muted", bundle: .module) }
    static var activityRunning: String { String(localized: "sidebar.a11y.running", defaultValue: "Agent running", bundle: .module) }
    static var activityNeedsInput: String { String(localized: "sidebar.a11y.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var activityError: String { String(localized: "sidebar.a11y.error", defaultValue: "Error", bundle: .module) }
    static var activityDone: String { String(localized: "sidebar.a11y.done", defaultValue: "Done", bundle: .module) }
    static var activityPaused: String { String(localized: "sidebar.a11y.paused", defaultValue: "Paused", bundle: .module) }
    static func activityProgress(_ percent: Int) -> String {
        String(format: String(localized: "sidebar.a11y.progress", defaultValue: "%d%% done", bundle: .module), percent)
    }

    /// Spoken status of a row's indicator, nil when idle.
    static func activity(_ state: StatusIndicatorState) -> String? {
        switch state {
        case .idle: nil
        case .busy, .working: state.progress.map { activityProgress(Int(($0 * 100).rounded())) } ?? activityRunning
        case .paused: activityPaused
        case .waiting: activityNeedsInput
        case .error: activityError
        case .success: activityDone
        }
    }
    static var closeButton: String { String(localized: "sidebar.a11y.closeWorkspace", defaultValue: "Close workspace", bundle: .module) }
    static func groupCount(_ value: Int) -> String { String(localized: "sidebar.a11y.groupCount", defaultValue: "\(value) workspaces", bundle: .module) }
    static var sidebarLabel: String { String(localized: "sidebar.a11y.sidebar", defaultValue: "Workspaces", bundle: .module) }
    static var newProfileName: String { String(localized: "sidebar.room.newName", defaultValue: "New Space", bundle: .module) }
    static var newProfile: String { String(localized: "sidebar.space.new", defaultValue: "New Space", bundle: .module) }
    static var profiles: String { String(localized: "sidebar.a11y.rooms", defaultValue: "Spaces", bundle: .module) }
    static func profileCurrent(_ name: String) -> String {
        String(localized: "sidebar.a11y.roomCurrent", defaultValue: "\(name), current space", bundle: .module)
    }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .module) }
}
