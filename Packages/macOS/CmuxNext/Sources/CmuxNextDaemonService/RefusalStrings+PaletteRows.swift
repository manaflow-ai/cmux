import Foundation

/// Why a palette row of a hand-built menu (cmux-tui's `hand_built_menus.rs`) refuses: the Back and
/// Forward lists, a screen sharing tab's quality menu, Show in Toolbar and Show in Tab Bar.
nonisolated extension RefusalStrings {
    public static var noHistoryEntry: String { text("handlers.refusal.noHistoryEntry", "That page is not in this tab's Back or Forward list.") }
    public static var noRemoteView: String { text("handlers.refusal.noRemoteView", "Select a screen sharing tab first.") }
    public static var noToolbarButton: String { text("handlers.refusal.noToolbarButton", "That button cannot be pinned here.") }
}
