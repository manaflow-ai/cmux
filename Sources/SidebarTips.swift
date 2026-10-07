import Foundation

/// One short "how to use cmux" tip shown by the sidebar footer's Tips button.
struct SidebarTip: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    /// Shortcut shown beside the title. It is read live from the user's
    /// bindings, so a rebound or unbound action never shows a wrong key.
    let shortcutAction: KeyboardShortcutSettings.Action?
    /// The tip describes the hold-Command shortcut hints, so it only applies
    /// while that setting is on.
    let requiresModifierHoldHints: Bool

    init(
        id: String,
        title: String,
        message: String,
        shortcutAction: KeyboardShortcutSettings.Action? = nil,
        requiresModifierHoldHints: Bool = false
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.shortcutAction = shortcutAction
        self.requiresModifierHoldHints = requiresModifierHoldHints
    }
}

/// The tips, in the order they are offered. Every tip names a real feature;
/// shortcuts come from `KeyboardShortcutSettings`, never from the copy.
enum SidebarTipsCatalog {
    static var all: [SidebarTip] {
        [
            SidebarTip(
                id: "commandPalette",
                title: String(localized: "sidebar.tips.commandPalette.title", defaultValue: "Command Palette"),
                message: String(
                    localized: "sidebar.tips.commandPalette.message",
                    defaultValue: "Run any cmux command by typing its name."
                ),
                shortcutAction: .commandPalette
            ),
            SidebarTip(
                id: "goToWorkspace",
                title: String(localized: "sidebar.tips.goToWorkspace.title", defaultValue: "Go to a workspace"),
                message: String(
                    localized: "sidebar.tips.goToWorkspace.message",
                    defaultValue: "Switch to any workspace by typing part of its name."
                ),
                shortcutAction: .goToWorkspace
            ),
            SidebarTip(
                id: "splitPanes",
                title: String(localized: "sidebar.tips.splitPanes.title", defaultValue: "Split panes"),
                message: String(
                    localized: "sidebar.tips.splitPanes.message",
                    defaultValue: "Put two terminals side by side in one workspace."
                ),
                shortcutAction: .splitRight
            ),
            SidebarTip(
                id: "zoomPane",
                title: String(localized: "sidebar.tips.zoomPane.title", defaultValue: "Zoom a pane"),
                message: String(
                    localized: "sidebar.tips.zoomPane.message",
                    defaultValue: "Let one pane fill the workspace for a while, then switch back to the split the same way."
                ),
                shortcutAction: .toggleSplitZoom
            ),
            SidebarTip(
                id: "browserSplit",
                title: String(localized: "sidebar.tips.browserSplit.title", defaultValue: "Browser next to your terminal"),
                message: String(
                    localized: "sidebar.tips.browserSplit.message",
                    defaultValue: "Open a browser pane beside your terminal, in the same workspace."
                ),
                shortcutAction: .splitBrowserRight
            ),
            SidebarTip(
                id: "jumpToUnread",
                title: String(localized: "sidebar.tips.jumpToUnread.title", defaultValue: "Jump to what needs you"),
                message: String(
                    localized: "sidebar.tips.jumpToUnread.message",
                    defaultValue: "Go straight to the latest unread notification, in whichever workspace it came from."
                ),
                shortcutAction: .jumpToUnread
            ),
            SidebarTip(
                id: "notifyCommand",
                title: String(localized: "sidebar.tips.notifyCommand.title", defaultValue: "Get notified when a command ends"),
                message: String(
                    localized: "sidebar.tips.notifyCommand.message",
                    defaultValue: "Put cmux notify after a long command, like make; cmux notify, and its pane lights up when it is done."
                )
            ),
            SidebarTip(
                id: "holdCommand",
                title: String(localized: "sidebar.tips.holdCommand.title", defaultValue: "Hold ⌘ for shortcuts"),
                message: String(
                    localized: "sidebar.tips.holdCommand.message",
                    defaultValue: "Holding ⌘ shows the shortcut for each workspace and a button that lists every shortcut."
                ),
                requiresModifierHoldHints: true
            ),
        ]
    }

    static func visibleTips(showsModifierHoldHints: Bool) -> [SidebarTip] {
        all.filter { !$0.requiresModifierHoldHints || showsModifierHoldHints }
    }
}

/// What the user has seen of the tips, persisted per Mac.
struct SidebarTipsProgress: Equatable {
    var currentTipID: String?
    var seenTipIDs: Set<String>
    /// Local calendar day (`yyyy-MM-dd`) the Tips popover was last opened.
    var lastOpenedDay: String?

    init(currentTipID: String? = nil, seenTipIDs: Set<String> = [], lastOpenedDay: String? = nil) {
        self.currentTipID = currentTipID
        self.seenTipIDs = seenTipIDs
        self.lastOpenedDay = lastOpenedDay
    }
}

/// Pure rules for which tip shows and when the footer button marks a new one.
///
/// At most one new tip a day: the button shows a small dot while some tip is
/// still unseen and the popover has not been opened today. Opening it on a
/// new day moves on to the next unseen tip. Once every tip has been seen the
/// dot never comes back, so it does not nag.
enum SidebarTipsSchedule {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04ld-%02ld-%02ld",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func showsNewTipIndicator(
        _ progress: SidebarTipsProgress,
        tipIDs: [String],
        today: String
    ) -> Bool {
        guard progress.lastOpenedDay != today else { return false }
        return tipIDs.contains { !progress.seenTipIDs.contains($0) }
    }

    static func currentIndex(_ progress: SidebarTipsProgress, tipIDs: [String]) -> Int {
        progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) } ?? 0
    }

    /// Progress after the popover opens on `today`.
    static func opened(
        _ progress: SidebarTipsProgress,
        tipIDs: [String],
        today: String
    ) -> SidebarTipsProgress {
        guard !tipIDs.isEmpty else { return progress }
        var next = progress
        let currentIndex = progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) }
        if let currentIndex {
            let isNewDay = progress.lastOpenedDay != today
            if isNewDay, progress.seenTipIDs.contains(tipIDs[currentIndex]) {
                let count = tipIDs.count
                let following = (1...count).map { tipIDs[(currentIndex + $0) % count] }
                next.currentTipID = following.first { !progress.seenTipIDs.contains($0) }
                    ?? tipIDs[(currentIndex + 1) % count]
            }
        } else {
            next.currentTipID = tipIDs.first { !progress.seenTipIDs.contains($0) } ?? tipIDs[0]
        }
        next.lastOpenedDay = today
        if let currentTipID = next.currentTipID {
            next.seenTipIDs.insert(currentTipID)
        }
        return next
    }

    /// Progress after the user pages to `tipID` inside the popover.
    static func selected(_ progress: SidebarTipsProgress, tipID: String) -> SidebarTipsProgress {
        var next = progress
        next.currentTipID = tipID
        next.seenTipIDs.insert(tipID)
        return next
    }
}

/// `UserDefaults` keys for `SidebarTipsProgress`. Seen ids are stored
/// comma-joined so `@AppStorage` can observe them across windows.
enum SidebarTipsStorage {
    static let currentTipIDKey = "sidebarTips.currentTipID"
    static let seenTipIDsKey = "sidebarTips.seenTipIDs"
    static let lastOpenedDayKey = "sidebarTips.lastOpenedDay"

    static func progress(currentTipID: String, seenTipIDs: String, lastOpenedDay: String) -> SidebarTipsProgress {
        SidebarTipsProgress(
            currentTipID: currentTipID.isEmpty ? nil : currentTipID,
            seenTipIDs: Set(seenTipIDs.split(separator: ",").map(String.init)),
            lastOpenedDay: lastOpenedDay.isEmpty ? nil : lastOpenedDay
        )
    }

    static func encodedSeenTipIDs(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}
