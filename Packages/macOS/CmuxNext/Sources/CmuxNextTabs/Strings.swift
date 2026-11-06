import Foundation

/// Localized strings for CmuxNextTabs. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var axStrip: String { String(localized: "tabs.ax.strip", defaultValue: "Tabs", bundle: .module) }
    static var axNewTab: String { String(localized: "tabs.ax.newTab", defaultValue: "New Tab", bundle: .module) }
    /// The + button's tooltip: a click opens a tab, holding it opens the new tab menu.
    static var newTabHoldHint: String {
        String(localized: "tabs.newTab.holdHint", defaultValue: "New Tab (hold for more)", bundle: .module)
    }
    /// A pane's "…" at the tab bar's trailing end (`PaneToolbarView`).
    static var paneMore: String { String(localized: "paneToolbar.more", defaultValue: "More", bundle: .module) }
    static var axClose: String { String(localized: "tabs.ax.close", defaultValue: "Close Tab", bundle: .module) }
    static func axOnMachine(_ name: String) -> String {
        String(localized: "tabs.ax.onMachine", defaultValue: "on \(name)", bundle: .module)
    }
    /// A tab's browser profile (hover card, VoiceOver).
    static func browserProfile(_ name: String) -> String {
        String(localized: "tabs.browserProfile", defaultValue: "Browser profile: \(name)", bundle: .module)
    }
    /// The terminal-theme dot, spoken (and shown in the hover card).
    static func axTheme(_ name: String) -> String {
        String(localized: "tabs.ax.theme", defaultValue: "theme \(name)", bundle: .module)
    }
    static var axPlayingAudio: String { String(localized: "tabs.ax.playingAudio", defaultValue: "Playing audio", bundle: .module) }
    /// A zoomed pane's indicator's tooltip (cmux classic's wording).
    static var exitZoom: String { String(localized: "tabs.zoom.exit", defaultValue: "Exit Zoom", bundle: .module) }
    /// VoiceOver: the tab's pane is zoomed (it shows the zoom indicator).
    static var axZoomed: String { String(localized: "tabs.ax.zoomed", defaultValue: "Zoomed", bundle: .module) }
    /// The speaker button's tooltip and VoiceOver action (Chrome's wording).
    static var muteTab: String { String(localized: "tabs.audio.mute", defaultValue: "Mute tab", bundle: .module) }
    static var unmuteTab: String { String(localized: "tabs.audio.unmute", defaultValue: "Unmute tab", bundle: .module) }
    static var axMuted: String { String(localized: "tabs.ax.muted", defaultValue: "Muted", bundle: .module) }
    static var axPinned: String { String(localized: "tabs.ax.pinned", defaultValue: "Pinned", bundle: .module) }
    static var axUnread: String { String(localized: "tabs.ax.unread", defaultValue: "Unread", bundle: .module) }
    static var axHibernated: String { String(localized: "tabs.ax.hibernated", defaultValue: "Hibernated", bundle: .module) }
    static var axBusy: String { String(localized: "tabs.ax.busy", defaultValue: "Running", bundle: .module) }
    static var axWorking: String { String(localized: "tabs.ax.working", defaultValue: "Agent working", bundle: .module) }
    static var axNeedsInput: String { String(localized: "tabs.ax.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var axSuccess: String { String(localized: "tabs.ax.success", defaultValue: "Done", bundle: .module) }
    static var axFailure: String { String(localized: "tabs.ax.failure", defaultValue: "Failed", bundle: .module) }
    static var hoverWorking: String { String(localized: "tabs.hoverCard.working", defaultValue: "Working", bundle: .module) }
    static var hoverIdle: String { String(localized: "tabs.hoverCard.idle", defaultValue: "Idle", bundle: .module) }
    /// A shell at its prompt that printed in the last minute ("Output · 12s").
    static var hoverOutput: String { String(localized: "tabs.hoverCard.output", defaultValue: "Output", bundle: .module) }
    static var hoverHibernated: String { String(localized: "tabs.hoverCard.hibernated", defaultValue: "Hibernated", bundle: .module) }
    static func hoverHibernatedWasUsing(_ memory: String) -> String {
        String(format: String(localized: "tabs.hoverCard.hibernatedWasUsing", defaultValue: "Hibernated · was using %@", bundle: .module), memory)
    }
    static func hoverMemory(_ memory: String) -> String {
        String(format: String(localized: "tabs.hoverCard.memory", defaultValue: "Memory %@", bundle: .module), memory)
    }
    static func hoverMemoryCPU(_ memory: String, _ cpu: String) -> String {
        String(format: String(localized: "tabs.hoverCard.memoryCPU", defaultValue: "Memory %1$@ · CPU %2$@", bundle: .module), memory, cpu)
    }
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
