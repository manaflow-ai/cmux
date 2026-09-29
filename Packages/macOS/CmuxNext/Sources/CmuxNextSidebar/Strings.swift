import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var searchPlaceholder: String { String(localized: "sidebar.search.placeholder", defaultValue: "Search Workspaces", bundle: .module) }
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .module) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var pinnedEmpty: String { String(localized: "sidebar.section.pinned.empty", defaultValue: "Drop here to pin", bundle: .module) }
    static var sectionEmpty: String { String(localized: "sidebar.section.empty", defaultValue: "No workspaces", bundle: .module) }
    static var noMatches: String { String(localized: "sidebar.search.noMatches", defaultValue: "No matching workspaces", bundle: .module) }
    static var rename: String { String(localized: "sidebar.menu.rename", defaultValue: "Rename", bundle: .module) }
    static var close: String { String(localized: "sidebar.menu.close", defaultValue: "Close Workspace", bundle: .module) }
    static func closeMany(_ value: Int) -> String { String(localized: "sidebar.menu.closeMany", defaultValue: "Close \(value) Workspaces", bundle: .module) }
    static var pin: String { String(localized: "sidebar.menu.pin", defaultValue: "Pin", bundle: .module) }
    static var unpin: String { String(localized: "sidebar.menu.unpin", defaultValue: "Unpin", bundle: .module) }
    static var newGroupFromSelection: String { String(localized: "sidebar.menu.newGroupFromSelection", defaultValue: "New Group from Selection", bundle: .module) }
    static var removeFromGroup: String { String(localized: "sidebar.menu.removeFromGroup", defaultValue: "Remove from Group", bundle: .module) }
    static var moveToGroup: String { String(localized: "sidebar.menu.moveToGroup", defaultValue: "Move to Group", bundle: .module) }
    static var color: String { String(localized: "sidebar.menu.color", defaultValue: "Color", bundle: .module) }
    static var icon: String { String(localized: "sidebar.menu.icon", defaultValue: "Icon", bundle: .module) }
    static var noColor: String { String(localized: "sidebar.menu.noColor", defaultValue: "None", bundle: .module) }
    static var renameGroup: String { String(localized: "sidebar.menu.renameGroup", defaultValue: "Rename Group", bundle: .module) }
    static var ungroup: String { String(localized: "sidebar.menu.ungroup", defaultValue: "Ungroup", bundle: .module) }
    static var newWorkspaceInGroup: String { String(localized: "sidebar.menu.newWorkspaceInGroup", defaultValue: "New Workspace in Group", bundle: .module) }
    static func newWorkspaceOnMachine(_ value: String) -> String { String(localized: "sidebar.menu.newWorkspaceOnMachine", defaultValue: "New Workspace on \(value)", bundle: .module) }
    static var defaultGroupName: String { String(localized: "sidebar.group.defaultName", defaultValue: "New Group", bundle: .module) }
    static var collapse: String { String(localized: "sidebar.menu.collapse", defaultValue: "Collapse", bundle: .module) }
    static var expand: String { String(localized: "sidebar.menu.expand", defaultValue: "Expand", bundle: .module) }
    static var showIconsOnly: String { String(localized: "sidebar.presentation.iconsOnly", defaultValue: "Show Icons Only", bundle: .module) }
    static var showFull: String { String(localized: "sidebar.presentation.expanded", defaultValue: "Show Full Sidebar", bundle: .module) }
    static var hideSidebar: String { String(localized: "sidebar.presentation.hide", defaultValue: "Hide Sidebar", bundle: .module) }
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
    static var account: String { String(localized: "sidebar.footer.account", defaultValue: "Account", bundle: .module) }
    static var cloud: String { String(localized: "sidebar.footer.cloud", defaultValue: "Cloud", bundle: .module) }
    static var status: String { String(localized: "sidebar.footer.status", defaultValue: "Status", bundle: .module) }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .module) }
    static var clearSearch: String { String(localized: "sidebar.search.clear", defaultValue: "Clear Search", bundle: .module) }

    static func color(_ color: SidebarColor) -> String {
        switch color {
        case .gray: String(localized: "sidebar.color.gray", defaultValue: "Gray", bundle: .module)
        case .red: String(localized: "sidebar.color.red", defaultValue: "Red", bundle: .module)
        case .orange: String(localized: "sidebar.color.orange", defaultValue: "Orange", bundle: .module)
        case .yellow: String(localized: "sidebar.color.yellow", defaultValue: "Yellow", bundle: .module)
        case .green: String(localized: "sidebar.color.green", defaultValue: "Green", bundle: .module)
        case .mint: String(localized: "sidebar.color.mint", defaultValue: "Mint", bundle: .module)
        case .cyan: String(localized: "sidebar.color.cyan", defaultValue: "Cyan", bundle: .module)
        case .blue: String(localized: "sidebar.color.blue", defaultValue: "Blue", bundle: .module)
        case .purple: String(localized: "sidebar.color.purple", defaultValue: "Purple", bundle: .module)
        case .pink: String(localized: "sidebar.color.pink", defaultValue: "Pink", bundle: .module)
        }
    }

    /// Icon choices offered in the context menu: (SF Symbol, label).
    static var iconChoices: [(symbol: String, label: String)] {
        [
            ("terminal", String(localized: "sidebar.icon.terminal", defaultValue: "Terminal", bundle: .module)),
            ("globe", String(localized: "sidebar.icon.globe", defaultValue: "Browser", bundle: .module)),
            ("hammer", String(localized: "sidebar.icon.hammer", defaultValue: "Build", bundle: .module)),
            ("ladybug", String(localized: "sidebar.icon.ladybug", defaultValue: "Debug", bundle: .module)),
            ("sparkles", String(localized: "sidebar.icon.sparkles", defaultValue: "Agent", bundle: .module)),
            ("server.rack", String(localized: "sidebar.icon.server.rack", defaultValue: "Server", bundle: .module)),
            ("doc.text", String(localized: "sidebar.icon.doc.text", defaultValue: "Docs", bundle: .module)),
            ("star", String(localized: "sidebar.icon.star", defaultValue: "Star", bundle: .module)),
        ]
    }
}
