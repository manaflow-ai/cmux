import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .module) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var pinnedEmpty: String { String(localized: "sidebar.section.pinned.empty", defaultValue: "Drop here to pin", bundle: .module) }
    static var sectionEmpty: String { String(localized: "sidebar.section.empty", defaultValue: "No workspaces", bundle: .module) }
    static var statusConnected: String { String(localized: "sidebar.machine.connected", defaultValue: "Connected", bundle: .module) }
    static var statusConnecting: String { String(localized: "sidebar.machine.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var statusOffline: String { String(localized: "sidebar.machine.offline", defaultValue: "Offline", bundle: .module) }
    static func unreadCount(_ value: Int) -> String { String(localized: "sidebar.a11y.unread", defaultValue: "\(value) unread", bundle: .module) }
    static var unreadDot: String { String(localized: "sidebar.a11y.unreadDot", defaultValue: "Unread", bundle: .module) }
    static var activityRunning: String { String(localized: "sidebar.a11y.running", defaultValue: "Agent running", bundle: .module) }
    static var activityNeedsInput: String { String(localized: "sidebar.a11y.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var activityError: String { String(localized: "sidebar.a11y.error", defaultValue: "Error", bundle: .module) }
    static var closeButton: String { String(localized: "sidebar.a11y.closeWorkspace", defaultValue: "Close workspace", bundle: .module) }
    static func groupCount(_ value: Int) -> String { String(localized: "sidebar.a11y.groupCount", defaultValue: "\(value) workspaces", bundle: .module) }
    static var sidebarLabel: String { String(localized: "sidebar.a11y.sidebar", defaultValue: "Workspaces", bundle: .module) }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .module) }
}
