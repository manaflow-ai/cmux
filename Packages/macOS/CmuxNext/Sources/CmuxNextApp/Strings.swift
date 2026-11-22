import Foundation

/// Localized strings for the app module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var appName: String { String(localized: "app.name", defaultValue: "cmux", bundle: .module.inAppLanguage) }

    static var menuHide: String { String(localized: "menu.app.hide", defaultValue: "Hide cmux", bundle: .module.inAppLanguage) }
    static var menuHideOthers: String { String(localized: "menu.app.hideOthers", defaultValue: "Hide Others", bundle: .module.inAppLanguage) }
    static var menuShowAll: String { String(localized: "menu.app.showAll", defaultValue: "Show All", bundle: .module.inAppLanguage) }
    static var menuFile: String { String(localized: "menu.file", defaultValue: "File", bundle: .module.inAppLanguage) }
    static var menuEdit: String { String(localized: "menu.edit", defaultValue: "Edit", bundle: .module.inAppLanguage) }
    static var menuUndo: String { String(localized: "menu.edit.undo", defaultValue: "Undo", bundle: .module.inAppLanguage) }
    static var menuRedo: String { String(localized: "menu.edit.redo", defaultValue: "Redo", bundle: .module.inAppLanguage) }
    static var menuCut: String { String(localized: "menu.edit.cut", defaultValue: "Cut", bundle: .module.inAppLanguage) }
    static var menuCopy: String { String(localized: "menu.edit.copy", defaultValue: "Copy", bundle: .module.inAppLanguage) }
    static var menuPaste: String { String(localized: "menu.edit.paste", defaultValue: "Paste", bundle: .module.inAppLanguage) }
    static var menuPasteAndMatchStyle: String {
        String(localized: "menu.edit.pasteAndMatchStyle", defaultValue: "Paste and Match Style", bundle: .module.inAppLanguage)
    }
    static var menuSelectAll: String { String(localized: "menu.edit.selectAll", defaultValue: "Select All", bundle: .module.inAppLanguage) }
    static var menuView: String { String(localized: "menu.view", defaultValue: "View", bundle: .module.inAppLanguage) }
    static var menuWindow: String { String(localized: "menu.window", defaultValue: "Window", bundle: .module.inAppLanguage) }
    static var menuHelp: String { String(localized: "menu.help", defaultValue: "Help", bundle: .module.inAppLanguage) }
    static var menuServer: String { String(localized: "menu.server", defaultValue: "Server", bundle: .module.inAppLanguage) }
    static var menuMinimize: String { String(localized: "menu.window.minimize", defaultValue: "Minimize", bundle: .module.inAppLanguage) }
    static var menuZoom: String { String(localized: "menu.window.zoom", defaultValue: "Zoom", bundle: .module.inAppLanguage) }

    static var localMachine: String { String(localized: "sidebar.machine.local", defaultValue: "This Mac", bundle: .module.inAppLanguage) }
    static var untitledTerminal: String { String(localized: "tab.untitled.terminal", defaultValue: "Terminal", bundle: .module.inAppLanguage) }
    static var untitledBrowser: String { String(localized: "tab.untitled.browser", defaultValue: "New Tab", bundle: .module.inAppLanguage) }
    static var cancel: String { String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module.inAppLanguage) }
}
