import Foundation

/// Localized strings for the app module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var appName: String { String(localized: "app.name", defaultValue: "cmux", bundle: .module) }

    static var menuHide: String { String(localized: "menu.app.hide", defaultValue: "Hide cmux", bundle: .module) }
    static var menuHideOthers: String { String(localized: "menu.app.hideOthers", defaultValue: "Hide Others", bundle: .module) }
    static var menuShowAll: String { String(localized: "menu.app.showAll", defaultValue: "Show All", bundle: .module) }
    static var menuFile: String { String(localized: "menu.file", defaultValue: "File", bundle: .module) }
    static var menuEdit: String { String(localized: "menu.edit", defaultValue: "Edit", bundle: .module) }
    static var menuUndo: String { String(localized: "menu.edit.undo", defaultValue: "Undo", bundle: .module) }
    static var menuRedo: String { String(localized: "menu.edit.redo", defaultValue: "Redo", bundle: .module) }
    static var menuCut: String { String(localized: "menu.edit.cut", defaultValue: "Cut", bundle: .module) }
    static var menuCopy: String { String(localized: "menu.edit.copy", defaultValue: "Copy", bundle: .module) }
    static var menuPaste: String { String(localized: "menu.edit.paste", defaultValue: "Paste", bundle: .module) }
    static var menuSelectAll: String { String(localized: "menu.edit.selectAll", defaultValue: "Select All", bundle: .module) }
    static var menuView: String { String(localized: "menu.view", defaultValue: "View", bundle: .module) }
    static var menuWindow: String { String(localized: "menu.window", defaultValue: "Window", bundle: .module) }
    static var menuHelp: String { String(localized: "menu.help", defaultValue: "Help", bundle: .module) }
    static var menuDebug: String { String(localized: "menu.debug", defaultValue: "Debug", bundle: .module) }
    static var menuSidebarToggleIcon: String {
        String(localized: "menu.debug.sidebarToggleIcon", defaultValue: "Sidebar Toggle Icon", bundle: .module)
    }
    static var menuStatusIcons: String {
        String(localized: "menu.debug.statusIcons", defaultValue: "Status Icons", bundle: .module)
    }
    static var menuSidebarPriority: String {
        String(localized: "menu.debug.sidebarPriority", defaultValue: "Sidebar Priority", bundle: .module)
    }
    static var menuSidebarPriorityFollowSetting: String {
        String(localized: "menu.debug.sidebarPriority.followSetting", defaultValue: "Follow Setting", bundle: .module)
    }
    static var menuSidebarPriorityManual: String {
        String(localized: "menu.debug.sidebarPriority.manual", defaultValue: "Manual Order", bundle: .module)
    }
    static var menuSidebarPriorityAttention: String {
        String(localized: "menu.debug.sidebarPriority.attention", defaultValue: "Attention First", bundle: .module)
    }
    static var menuMotion: String {
        String(localized: "menu.debug.motion", defaultValue: "Motion", bundle: .module)
    }
    static var menuMotionSpeed: String {
        String(localized: "menu.debug.motion.speed", defaultValue: "Animation Speed", bundle: .module)
    }
    static var menuMotionFast: String {
        String(localized: "menu.debug.motion.fast", defaultValue: "Fast", bundle: .module)
    }
    static var menuMotionNormal: String {
        String(localized: "menu.debug.motion.normal", defaultValue: "Normal", bundle: .module)
    }
    static var menuMotionOff: String {
        String(localized: "menu.debug.motion.off", defaultValue: "Off", bundle: .module)
    }
    static var menuMotionReduceMotion: String {
        String(localized: "menu.debug.motion.reduceMotion", defaultValue: "Reduce Motion", bundle: .module)
    }
    static var menuMotionFollowSystem: String {
        String(localized: "menu.debug.motion.followSystem", defaultValue: "Follow System", bundle: .module)
    }
    static var menuMotionEnabled: String {
        String(localized: "menu.debug.motion.enabled", defaultValue: "Enabled", bundle: .module)
    }
    static var menuMotionDisabled: String {
        String(localized: "menu.debug.motion.disabled", defaultValue: "Disabled", bundle: .module)
    }
    static var menuServer: String { String(localized: "menu.server", defaultValue: "Server", bundle: .module) }
    static var menuMinimize: String { String(localized: "menu.window.minimize", defaultValue: "Minimize", bundle: .module) }
    static var menuZoom: String { String(localized: "menu.window.zoom", defaultValue: "Zoom", bundle: .module) }

    static var localMachine: String { String(localized: "sidebar.machine.local", defaultValue: "This Mac", bundle: .module) }
    static var untitledTerminal: String { String(localized: "tab.untitled.terminal", defaultValue: "Terminal", bundle: .module) }
    static var untitledBrowser: String { String(localized: "tab.untitled.browser", defaultValue: "New Tab", bundle: .module) }
    static var renameTabTitle: String { String(localized: "rename.tab.title", defaultValue: "Rename Tab", bundle: .module) }
    static var renameConfirm: String { String(localized: "rename.confirm", defaultValue: "Rename", bundle: .module) }
    static var cancel: String { String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module) }
}
