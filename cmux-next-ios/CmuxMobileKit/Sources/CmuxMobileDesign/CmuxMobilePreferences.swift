import Foundation

/// Device-local preferences read below `CmuxMobileModel` (the terminal, code cards,
/// diffs, the agent composer). Settings writes them through `SettingsStore`
/// under these same `UserDefaults` keys; SwiftUI views read them with
/// `@AppStorage(CmuxMobilePreferences.Key...)` so a change applies at once.
public enum CmuxMobilePreferences {
    public enum Key {
        public static let terminalFontSize = "cmuxMobile.settings.terminalFontSize"
        public static let wrapCode = "cmuxMobile.settings.wrapCode"
        public static let keyClicks = "cmuxMobile.settings.keyClicks"
        public static let predictiveEcho = "cmuxMobile.settings.predictiveEcho"
        /// Settings → Terminal → Jump to Bottom Button (CMUX-10): off removes the
        /// terminal's Jump to bottom row above the composer.
        public static let terminalJumpToBottom = "cmuxMobile.settings.terminalJumpToBottom"
        /// Settings → Transport → Ultra Mode on Cellular; read at each dial (`FFIMacLinkDialer`).
        public static let ultraOnCellular = "cmuxMobile.settings.ultraOnCellular"
        public static let dismissKeyboardAfterSend = "cmuxMobile.settings.dismissKeyboardAfterSend"
        public static let followUp = "cmuxMobile.settings.followUp"
        /// Workspaces → one line per workspace (the Mac's Compact Workspace List).
        public static let compactWorkspaceList = "cmuxMobile.settings.compactWorkspaceList"
        /// Long-press menu items the person hid (Settings → Long-Press Menus), by item id.
        public static let hiddenMenuItems = "cmuxMobile.settings.hiddenMenuItems"
    }

    /// The terminal's font size in points when the person never changed it.
    public static let defaultTerminalFontSize = 12
    /// The sizes Settings offers (and the terminal accepts).
    public static let terminalFontSizes = 9...24
    public static let defaultWrapCode = false
    public static let defaultKeyClicks = true
    public static let defaultPredictiveEcho = true
    public static let defaultTerminalJumpToBottom = true
    public static let defaultDismissKeyboardAfterSend = true
    /// `FollowUpBehavior.steer.rawValue`: a message sent while the agent works
    /// interrupts it instead of waiting for the turn to end.
    public static let steerFollowUp = "steer"

    public static func terminalFontSize(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: Key.terminalFontSize) as? Int ?? defaultTerminalFontSize
        return min(max(stored, terminalFontSizes.lowerBound), terminalFontSizes.upperBound)
    }

    public static func wrapCode(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.wrapCode) as? Bool ?? defaultWrapCode
    }

    public static func keyClicks(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.keyClicks) as? Bool ?? defaultKeyClicks
    }

    public static func terminalJumpToBottom(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalJumpToBottom) == nil
            ? defaultTerminalJumpToBottom : defaults.bool(forKey: Key.terminalJumpToBottom)
    }

    /// Typed characters show at once over a slow link, underlined until the
    /// remote echoes them (the terminal's `TerminalSurfacePrediction`).
    public static func predictiveEcho(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.predictiveEcho) as? Bool ?? defaultPredictiveEcho
    }

    public static func dismissKeyboardAfterSend(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.dismissKeyboardAfterSend) as? Bool ?? defaultDismissKeyboardAfterSend
    }

    /// Whether prompt queueing is off: Queue (send after this turn) steers the running turn too
    /// (acpmux `_meta.acpmux.steer`), as the Mac's ⌘Return does then ([`steersMidTurn`]).
    public static func steersFollowUps(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: Key.followUp) == steerFollowUp
    }

    /// Whether a message sent while the agent works steers it, as the Mac's composer decides:
    /// Send and Return steer the turn (Leo, 2026-11-05: "WHY THE F*** ARE MY MESSAGES BEING
    /// QUEUED INSTEAD OF STEERING"); only Queue (send after this turn), the Mac's ⌘Return, waits
    /// for the turn, and with queueing off it steers too. An agent that cannot steer still runs
    /// it after the turn.
    public static func steersMidTurn(queue: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        !queue || steersFollowUps(defaults)
    }

    /// The Mac's Toggle Prompt Queueing, from a chat: queueing on (a message sent mid-turn waits
    /// for the turn) or off (it steers the turn, acpmux `_meta.acpmux.steer`). One choice for every
    /// chat, as on the Mac; Settings → Composer shows the same choice.
    public static func setQueueing(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on ? queueFollowUp : steerFollowUp, forKey: Key.followUp)
    }

    /// `FollowUpBehavior.queue.rawValue`.
    public static let queueFollowUp = "queue"

    public static func compactWorkspaceList(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.compactWorkspaceList)
    }
}

/// Settings → Long-Press Menus (the Mac's Customize Right-Click Menus…): items the person hid
/// from the phone's long-press menus. Only hiding is offered; the order stays the Mac's.
public enum CmuxMobileMenuCustomization {
    /// One menu the person can trim, and the items it offers there.
    public struct Menu: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var items: [Item]
    }

    public struct Item: Identifiable, Sendable, Equatable {
        /// `<menu>.<item>`: stable across launches and languages.
        public var id: String
        public var title: String
        public var systemImage: String
    }

    /// The menus Settings lists, with every item that can be hidden.
    public static let menus: [Menu] = [
        Menu(id: "workspaceRow", title: String(localized: "Workspace rows"), items: [
            Item(id: "workspaceRow.tabs", title: String(localized: "Tabs"), systemImage: "square.on.square"),
            Item(id: "workspaceRow.sendMessage", title: String(localized: "Send Message…"), systemImage: "paperplane"),
            Item(id: "workspaceRow.arrange", title: String(localized: "Pin, Appearance, Options, Group and Move"), systemImage: "pin"),
            Item(id: "workspaceRow.rename", title: String(localized: "Rename"), systemImage: "pencil"),
            Item(id: "workspaceRow.duplicate", title: String(localized: "Duplicate Workspace"), systemImage: "plus.square.on.square"),
            Item(id: "workspaceRow.bulkClose", title: String(localized: "Close Other Workspaces and Others"), systemImage: "xmark.square"),
        ]),
        Menu(id: "homeRow", title: String(localized: "Home conversations"), items: [
            Item(id: "homeRow.pin", title: String(localized: "Pin"), systemImage: "pin"),
            Item(id: "homeRow.read", title: String(localized: "Mark as Read or Unread"), systemImage: "message.badge"),
            Item(id: "homeRow.delete", title: String(localized: "Delete Conversation from List"), systemImage: "trash"),
        ]),
    ]

    public static func hidden(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: CmuxMobilePreferences.Key.hiddenMenuItems) ?? [])
    }

    public static func isShown(_ id: String, _ defaults: UserDefaults = .standard) -> Bool {
        !hidden(defaults).contains(id)
    }

    public static func setShown(_ shown: Bool, _ id: String, _ defaults: UserDefaults = .standard) {
        var set = hidden(defaults)
        if shown { set.remove(id) } else { set.insert(id) }
        if set.isEmpty {
            defaults.removeObject(forKey: CmuxMobilePreferences.Key.hiddenMenuItems)
        } else {
            defaults.set(set.sorted(), forKey: CmuxMobilePreferences.Key.hiddenMenuItems)
        }
    }

    /// Every item shown again.
    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: CmuxMobilePreferences.Key.hiddenMenuItems)
    }
}
