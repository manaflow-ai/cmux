import Foundation

/// Localized strings for CmuxNextTabs. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var menuClose: String { String(localized: "tabs.menu.close", defaultValue: "Close Tab", bundle: .module) }
    static var menuCloseOthers: String { String(localized: "tabs.menu.closeOthers", defaultValue: "Close Other Tabs", bundle: .module) }
    static var menuCloseToRight: String { String(localized: "tabs.menu.closeToRight", defaultValue: "Close Tabs to the Right", bundle: .module) }
    static var menuPin: String { String(localized: "tabs.menu.pin", defaultValue: "Pin Tab", bundle: .module) }
    static var menuUnpin: String { String(localized: "tabs.menu.unpin", defaultValue: "Unpin Tab", bundle: .module) }
    static var menuRename: String { String(localized: "tabs.menu.rename", defaultValue: "Rename Tab…", bundle: .module) }
    static var menuDuplicate: String { String(localized: "tabs.menu.duplicate", defaultValue: "Duplicate Tab", bundle: .module) }
    static var menuSplitRight: String { String(localized: "tabs.menu.splitRight", defaultValue: "Move to New Split Right", bundle: .module) }
    static var menuSplitDown: String { String(localized: "tabs.menu.splitDown", defaultValue: "Move to New Split Down", bundle: .module) }
    static var menuNewColumn: String { String(localized: "tabs.menu.newColumn", defaultValue: "Move to New Column", bundle: .module) }
    static var menuNewTab: String { String(localized: "tabs.menu.newTab", defaultValue: "New Tab", bundle: .module) }
    static var axStrip: String { String(localized: "tabs.ax.strip", defaultValue: "Tabs", bundle: .module) }
    static var axNewTab: String { String(localized: "tabs.ax.newTab", defaultValue: "New Tab", bundle: .module) }
    static var axClose: String { String(localized: "tabs.ax.close", defaultValue: "Close Tab", bundle: .module) }
    static var axPinned: String { String(localized: "tabs.ax.pinned", defaultValue: "Pinned", bundle: .module) }
    static var axUnread: String { String(localized: "tabs.ax.unread", defaultValue: "Unread", bundle: .module) }
    static var axBusy: String { String(localized: "tabs.ax.busy", defaultValue: "Running", bundle: .module) }
    static var axNeedsInput: String { String(localized: "tabs.ax.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var axSuccess: String { String(localized: "tabs.ax.success", defaultValue: "Done", bundle: .module) }
    static var axFailure: String { String(localized: "tabs.ax.failure", defaultValue: "Failed", bundle: .module) }
    static var untitled: String { String(localized: "tabs.untitled", defaultValue: "Untitled", bundle: .module) }
    static var demoWindowTitle: String { String(localized: "tabs.demo.windowTitle", defaultValue: "Tab Strip Demo", bundle: .module) }
    static var demoAddTab: String { String(localized: "tabs.demo.addTab", defaultValue: "Add Tab", bundle: .module) }
    static var demoAddMany: String { String(localized: "tabs.demo.addMany", defaultValue: "Add 10 Tabs", bundle: .module) }
    static var demoToggleBusy: String { String(localized: "tabs.demo.toggleBusy", defaultValue: "Toggle Busy", bundle: .module) }
    static var demoToggleUnread: String { String(localized: "tabs.demo.toggleUnread", defaultValue: "Toggle Unread", bundle: .module) }
    static var demoCycleStatus: String { String(localized: "tabs.demo.cycleStatus", defaultValue: "Cycle Status", bundle: .module) }
    static var demoCompact: String { String(localized: "tabs.demo.compact", defaultValue: "Compact Style", bundle: .module) }
    static func demoLog(_ intent: String) -> String {
        String(localized: "tabs.demo.log", defaultValue: "Last intent: \(intent)", bundle: .module)
    }
}
