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
        case .window: ("\u{E000}Localizable\u{E001}" + String(describing: "category.window") + "\u{E002}" + String(localized: "category.window", defaultValue: "Window", bundle: .module))
        case .workspace: ("\u{E000}Localizable\u{E001}" + String(describing: "category.workspace") + "\u{E002}" + String(localized: "category.workspace", defaultValue: "Workspace", bundle: .module))
        case .pane: ("\u{E000}Localizable\u{E001}" + String(describing: "category.pane") + "\u{E002}" + String(localized: "category.pane", defaultValue: "Panes", bundle: .module))
        case .screen: ("\u{E000}ScreenActions\u{E001}" + String(describing: "category.screen") + "\u{E002}" + String(localized: "category.screen", defaultValue: "Screens", table: "ScreenActions", bundle: .module))
        case .tab: ("\u{E000}Localizable\u{E001}" + String(describing: "category.tab") + "\u{E002}" + String(localized: "category.tab", defaultValue: "Tabs", bundle: .module))
        case .terminal: ("\u{E000}Localizable\u{E001}" + String(describing: "category.terminal") + "\u{E002}" + String(localized: "category.terminal", defaultValue: "Terminal", bundle: .module))
        case .browser: ("\u{E000}Localizable\u{E001}" + String(describing: "category.browser") + "\u{E002}" + String(localized: "category.browser", defaultValue: "Browser and Viewers", bundle: .module))
        case .sidebar: ("\u{E000}Localizable\u{E001}" + String(describing: "category.sidebar") + "\u{E002}" + String(localized: "category.sidebar", defaultValue: "Sidebar", bundle: .module))
        case .notifications: ("\u{E000}Localizable\u{E001}" + String(describing: "category.notifications") + "\u{E002}" + String(localized: "category.notifications", defaultValue: "Notifications", bundle: .module))
        case .agents: ("\u{E000}Localizable\u{E001}" + String(describing: "category.agents") + "\u{E002}" + String(localized: "category.agents", defaultValue: "Agents", bundle: .module))
        case .cloud: ("\u{E000}Localizable\u{E001}" + String(describing: "category.cloud") + "\u{E002}" + String(localized: "category.cloud", defaultValue: "Cloud and Account", bundle: .module))
        case .remote: ("\u{E000}RemoteActions\u{E001}" + String(describing: "category.remote") + "\u{E002}" + String(localized: "category.remote", defaultValue: "Remote Machines", table: "RemoteActions", bundle: .module))
        case .settings: ("\u{E000}Localizable\u{E001}" + String(describing: "category.settings") + "\u{E002}" + String(localized: "category.settings", defaultValue: "Settings and Help", bundle: .module))
        case .other: ("\u{E000}Localizable\u{E001}" + String(describing: "category.other") + "\u{E002}" + String(localized: "category.other", defaultValue: "Other", bundle: .module))
        }
    }

    /// The localization key of ``title`` (in ``titleTable``), for clients
    /// that read the exported catalog (`action-surfaces.json`).
    public var titleKey: String { "category.\(rawValue)" }

    /// The string table ``title`` lives in.
    public var titleTable: String {
        switch self {
        case .screen: "ScreenActions"
        case .remote: "RemoteActions"
        default: "Localizable"
        }
    }

    /// The command palette section the category's actions list under.
    public var paletteSectionID: String { "category.\(rawValue)" }

    /// The palette section's order (after the palette's own sections).
    public var paletteSectionOrder: Int { 100 + sortOrder }

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
    /// Servers the user runs things on (Add Server…, the server panel).
    case server
    case window
    case help
    /// DEV and NIGHTLY only (`DevTools`): debug-only actions.
    case debug
}
