import Foundation

/// Localized strings for CmuxNextTabs. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static var axStrip: String { String(localized: "tabs.ax.strip", defaultValue: "Tabs", bundle: .localizedModule) }
    static var axNewTab: String { String(localized: "tabs.ax.newTab", defaultValue: "New Tab", bundle: .localizedModule) }
    /// "More": the tab group editor's overflow row.
    static var paneMore: String { String(localized: "paneToolbar.more", defaultValue: "More", bundle: .localizedModule) }
    static var axClose: String { String(localized: "tabs.ax.close", defaultValue: "Close Tab", bundle: .localizedModule) }
    /// A Cloud chat's machine badge (drawn as a cloud): what VoiceOver says it runs on.
    static var cloudMachineBadge: String { String(localized: "tabs.machineBadge.cloud", defaultValue: "Cloud", bundle: .localizedModule) }
    static func axOnMachine(_ name: String) -> String {
        String(localized: "tabs.ax.onMachine", defaultValue: "on \(name)", bundle: .localizedModule)
    }
    /// A tab's browser profile (hover card, VoiceOver).
    static func browserProfile(_ name: String) -> String {
        String(localized: "tabs.browserProfile", defaultValue: "Browser profile: \(name)", bundle: .localizedModule)
    }
    /// The terminal-theme dot, spoken (and shown in the hover card).
    static func axTheme(_ name: String) -> String {
        String(localized: "tabs.ax.theme", defaultValue: "theme \(name)", bundle: .localizedModule)
    }
    static var axPlayingAudio: String { String(localized: "tabs.ax.playingAudio", defaultValue: "Playing audio", bundle: .localizedModule) }
    /// A zoomed pane's indicator's tooltip and VoiceOver label (cmux classic's wording).
    static var exitZoom: String { String(localized: "tabs.zoom.exit", defaultValue: "Exit Zoom", bundle: .localizedModule) }
    /// VoiceOver: the tab's pane is zoomed.
    static var axZoomed: String { String(localized: "tabs.ax.zoomed", defaultValue: "Zoomed", bundle: .localizedModule) }
    /// The speaker button's tooltip and VoiceOver action (Chrome's wording).
    static var muteTab: String { String(localized: "tabs.audio.mute", defaultValue: "Mute tab", bundle: .localizedModule) }
    static var unmuteTab: String { String(localized: "tabs.audio.unmute", defaultValue: "Unmute tab", bundle: .localizedModule) }
    static var axMuted: String { String(localized: "tabs.ax.muted", defaultValue: "Muted", bundle: .localizedModule) }
    static var axPinned: String { String(localized: "tabs.ax.pinned", defaultValue: "Pinned", bundle: .localizedModule) }
    static var axUnread: String { String(localized: "tabs.ax.unread", defaultValue: "Unread", bundle: .localizedModule) }
    static var axHibernated: String { String(localized: "tabs.ax.hibernated", defaultValue: "Hibernated", bundle: .localizedModule) }
    static var axBusy: String { String(localized: "tabs.ax.busy", defaultValue: "Running", bundle: .localizedModule) }
    static var axWorking: String { String(localized: "tabs.ax.working", defaultValue: "Agent working", bundle: .localizedModule) }
    static var axNeedsInput: String { String(localized: "tabs.ax.needsInput", defaultValue: "Needs input", bundle: .localizedModule) }
    static var axSuccess: String { String(localized: "tabs.ax.success", defaultValue: "Done", bundle: .localizedModule) }
    static var axFailure: String { String(localized: "tabs.ax.failure", defaultValue: "Failed", bundle: .localizedModule) }
    static var hoverWorking: String { String(localized: "tabs.hoverCard.working", defaultValue: "Working", bundle: .localizedModule) }
    static var hoverIdle: String { String(localized: "tabs.hoverCard.idle", defaultValue: "Idle", bundle: .localizedModule) }
    /// A shell at its prompt that printed in the last minute ("Output · 12s").
    static var hoverOutput: String { String(localized: "tabs.hoverCard.output", defaultValue: "Output", bundle: .localizedModule) }
    static var hoverHibernated: String { String(localized: "tabs.hoverCard.hibernated", defaultValue: "Hibernated", bundle: .localizedModule) }
    static func hoverHibernatedWasUsing(_ memory: String) -> String {
        String(format: String(localized: "tabs.hoverCard.hibernatedWasUsing", defaultValue: "Hibernated · was using %@", bundle: .localizedModule), memory)
    }
    static func hoverMemory(_ memory: String) -> String {
        String(format: String(localized: "tabs.hoverCard.memory", defaultValue: "Memory %@", bundle: .localizedModule), memory)
    }
    static func hoverMemoryCPU(_ memory: String, _ cpu: String) -> String {
        String(format: String(localized: "tabs.hoverCard.memoryCPU", defaultValue: "Memory %1$@ · CPU %2$@", bundle: .localizedModule), memory, cpu)
    }
    static var untitled: String { String(localized: "tabs.untitled", defaultValue: "Untitled", bundle: .localizedModule) }
    static var renameField: String { String(localized: "tabs.renameField", defaultValue: "Tab name", bundle: .localizedModule) }
    static var demoWindowTitle: String { String(localized: "tabs.demo.windowTitle", defaultValue: "Tab Strip Demo", bundle: .localizedModule) }
    static var demoAddTab: String { String(localized: "tabs.demo.addTab", defaultValue: "Add Tab", bundle: .localizedModule) }
    static var demoAddMany: String { String(localized: "tabs.demo.addMany", defaultValue: "Add 10 Tabs", bundle: .localizedModule) }
    static var demoToggleBusy: String { String(localized: "tabs.demo.toggleBusy", defaultValue: "Toggle Busy", bundle: .localizedModule) }
    static var demoToggleUnread: String { String(localized: "tabs.demo.toggleUnread", defaultValue: "Toggle Unread", bundle: .localizedModule) }
    static var demoCycleStatus: String { String(localized: "tabs.demo.cycleStatus", defaultValue: "Cycle Status", bundle: .localizedModule) }
    static var demoCompact: String { String(localized: "tabs.demo.compact", defaultValue: "Compact Style", bundle: .localizedModule) }
    static func demoLog(_ intent: String) -> String {
        String(localized: "tabs.demo.log", defaultValue: "Last intent: \(intent)", bundle: .localizedModule)
    }
}
