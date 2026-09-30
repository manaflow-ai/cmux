import Foundation

/// Localized strings for CmuxNextTabs. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var axStrip: String { String(localized: "tabs.ax.strip", defaultValue: "Tabs", bundle: .module) }
    static var axNewTab: String { String(localized: "tabs.ax.newTab", defaultValue: "New Tab", bundle: .module) }
    static var axClose: String { String(localized: "tabs.ax.close", defaultValue: "Close Tab", bundle: .module) }
    static func axOnMachine(_ name: String) -> String {
        String(localized: "tabs.ax.onMachine", defaultValue: "on \(name)", bundle: .module)
    }
    /// A tab's browser profile (hover card, VoiceOver).
    static func browserProfile(_ name: String) -> String {
        String(localized: "tabs.browserProfile", defaultValue: "Browser profile: \(name)", bundle: .module)
    }
    static var axPinned: String { String(localized: "tabs.ax.pinned", defaultValue: "Pinned", bundle: .module) }
    static var axUnread: String { String(localized: "tabs.ax.unread", defaultValue: "Unread", bundle: .module) }
    static var axHibernated: String { String(localized: "tabs.ax.hibernated", defaultValue: "Hibernated", bundle: .module) }
    static var axBusy: String { String(localized: "tabs.ax.busy", defaultValue: "Running", bundle: .module) }
    static var axNeedsInput: String { String(localized: "tabs.ax.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var axSuccess: String { String(localized: "tabs.ax.success", defaultValue: "Done", bundle: .module) }
    static var axFailure: String { String(localized: "tabs.ax.failure", defaultValue: "Failed", bundle: .module) }
    static var untitled: String { String(localized: "tabs.untitled", defaultValue: "Untitled", bundle: .module) }
    static var renameField: String { String(localized: "tabs.renameField", defaultValue: "Tab name", bundle: .module) }
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
