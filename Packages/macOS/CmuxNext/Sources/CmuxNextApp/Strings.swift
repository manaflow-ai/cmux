import Foundation

/// Localized strings for the app module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var appName: String { String(localized: "app.name", defaultValue: "cmux", bundle: .module) }

    static var menuAbout: String { String(localized: "menu.app.about", defaultValue: "About cmux", bundle: .module) }
    static var menuHide: String { String(localized: "menu.app.hide", defaultValue: "Hide cmux", bundle: .module) }
    static var menuHideOthers: String { String(localized: "menu.app.hideOthers", defaultValue: "Hide Others", bundle: .module) }
    static var menuShowAll: String { String(localized: "menu.app.showAll", defaultValue: "Show All", bundle: .module) }
    static var menuFile: String { String(localized: "menu.file", defaultValue: "File", bundle: .module) }
    static var menuView: String { String(localized: "menu.view", defaultValue: "View", bundle: .module) }
    static var menuWindow: String { String(localized: "menu.window", defaultValue: "Window", bundle: .module) }
    static var menuMinimize: String { String(localized: "menu.window.minimize", defaultValue: "Minimize", bundle: .module) }
    static var menuZoom: String { String(localized: "menu.window.zoom", defaultValue: "Zoom", bundle: .module) }

    static var actionQuit: String { String(localized: "action.app.quit", defaultValue: "Quit cmux", bundle: .module) }
    static var actionNewTab: String { String(localized: "action.tab.new", defaultValue: "New Tab", bundle: .module) }
    static var actionCloseTab: String { String(localized: "action.tab.close", defaultValue: "Close Tab", bundle: .module) }
    static var actionNextTab: String { String(localized: "action.tab.next", defaultValue: "Show Next Tab", bundle: .module) }
    static var actionPreviousTab: String { String(localized: "action.tab.previous", defaultValue: "Show Previous Tab", bundle: .module) }
    static var actionToggleSidebar: String { String(localized: "action.view.toggleSidebar", defaultValue: "Toggle Sidebar", bundle: .module) }
    static var actionCommandPalette: String { String(localized: "action.palette.show", defaultValue: "Command Palette", bundle: .module) }

    static var sidebarTitle: String { String(localized: "sidebar.title", defaultValue: "Workspaces", bundle: .module) }
    static var defaultWorkspace: String { String(localized: "sidebar.workspace.default", defaultValue: "Default", bundle: .module) }

    static func tabTitle(_ number: Int) -> String {
        String(localized: "tab.title", defaultValue: "Terminal \(number)", bundle: .module)
    }

    static var placeholderTitle: String { String(localized: "content.placeholder.title", defaultValue: "cmux next", bundle: .module) }
    static var placeholderSubtitle: String {
        String(localized: "content.placeholder.subtitle", defaultValue: "Terminal surfaces attach here once the daemon client lands.", bundle: .module)
    }
    static func placeholderTag(_ tag: String) -> String {
        String(localized: "content.placeholder.tag", defaultValue: "Tag: \(tag)", bundle: .module)
    }
}
