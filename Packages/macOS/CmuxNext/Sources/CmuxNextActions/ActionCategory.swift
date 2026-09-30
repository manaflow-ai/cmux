import Foundation

/// Functional domain of an action. Matches the sections of the action catalog
/// in plans/cmux-next/inventory.md section 1.
public nonisolated enum ActionCategory: String, CaseIterable, Sendable, Hashable {
    case window
    case workspace
    case pane
    case screen
    case tab
    case terminal
    case browser
    case sidebar
    case notifications
    case agents
    case cloud
    /// SSH machines (Connect to Machine…).
    case remote
    case settings
    /// Actions registered at runtime without a catalog descriptor.
    case other

    /// Localized section title.
    public var title: String {
        switch self {
        case .window: String(localized: "category.window", defaultValue: "Window", bundle: .module)
        case .workspace: String(localized: "category.workspace", defaultValue: "Workspace", bundle: .module)
        case .pane: String(localized: "category.pane", defaultValue: "Panes", bundle: .module)
        case .screen: String(localized: "category.screen", defaultValue: "Screens", table: "ScreenActions", bundle: .module)
        case .tab: String(localized: "category.tab", defaultValue: "Tabs", bundle: .module)
        case .terminal: String(localized: "category.terminal", defaultValue: "Terminal", bundle: .module)
        case .browser: String(localized: "category.browser", defaultValue: "Browser and Viewers", bundle: .module)
        case .sidebar: String(localized: "category.sidebar", defaultValue: "Sidebar", bundle: .module)
        case .notifications: String(localized: "category.notifications", defaultValue: "Notifications", bundle: .module)
        case .agents: String(localized: "category.agents", defaultValue: "Agents", bundle: .module)
        case .cloud: String(localized: "category.cloud", defaultValue: "Cloud and Account", bundle: .module)
        case .remote: String(localized: "category.remote", defaultValue: "Remote Machines", table: "RemoteActions", bundle: .module)
        case .settings: String(localized: "category.settings", defaultValue: "Settings and Help", bundle: .module)
        case .other: String(localized: "category.other", defaultValue: "Other", bundle: .module)
        }
    }

    /// Display order of category sections.
    public var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// Top-level menus of the menu bar. The App builds each from the actions
/// whose `mainMenu` names it, in catalog order.
public nonisolated enum ActionMainMenu: String, CaseIterable, Sendable, Hashable {
    case app
    case file
    case edit
    case view
    case window
    case help
}
