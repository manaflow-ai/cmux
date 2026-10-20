import AppKit
import Foundation

@MainActor
enum MenuBarProfilingMenuItem {
    static func make() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "statusMenu.startProfiling", defaultValue: "Start Profiling"),
            action: #selector(MenuBarProfilingMenuItemTarget.startProfiling(_:)),
            keyEquivalent: ""
        )
        item.target = MenuBarProfilingMenuItemTarget.shared
        return item
    }
}
