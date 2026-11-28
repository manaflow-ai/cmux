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
        /// Settings → Terminal → Predictive Echo in Full-Screen Apps (off by default): typing
        /// into Claude Code, Codex or vim's insert mode is predicted too, each key confirmed
        /// in its cell. Read by the terminal (`TerminalSurfacePrediction`).
        public static let predictiveEchoFullScreen = "cmuxMobile.settings.predictiveEchoFullScreen"
        /// Settings → Terminal → Fit to Phone: on resizes the Mac's terminal to
        /// the phone (as before); off, the phone re-wraps it at its own width.
        public static let terminalFitToPhone = "cmuxMobile.settings.terminalFitToPhone"
        /// Settings → Terminal → Jump to Bottom Button (CMUX-10): off removes the
        /// terminal's Jump to bottom row above the composer.
        public static let terminalJumpToBottom = "cmuxMobile.settings.terminalJumpToBottom"
        /// The terminal composer's Autocorrect toggle (its + menu, Settings → Terminal).
        public static let terminalComposerAutocorrect = "cmuxMobile.settings.terminalComposerAutocorrect"
        /// Settings → Terminal → Terminal and Chat Toggle (off by default; Leo, 2026-11-17: "the
        /// toggle js just so a** rn it needs more baking tiem"): on, a Claude Code or Codex tab's
        /// page menu offers Show Chat / Show Terminal where both faces work.
        public static let terminalChatToggle = "cmuxMobile.settings.terminalChatToggle"
        /// Settings → Terminal → Plain Scroll in Full-Screen Apps (off by default; Leo, 2026-11-24: "we can
        /// just treat the scroll like any pedestrian scroll"): on, a drag toward older rows in a full-screen
        /// app scrolls the rows the phone kept (`TerminalTUIReader`), not the app's wheel.
        public static let terminalPlainScroll = "cmuxMobile.settings.terminalPlainScroll"
        /// Settings → Terminal → Zoom Full-Screen Apps (off by default; Leo, 2026-11-17: "Surely we
        /// can just calculate a f***ing terminal and resize whatever needs exceptions when it comes /
        /// Fall back if need be"): on, a full-screen app shows at the Mac's grid, zoomed, and only
        /// typing into it resizes the Mac (`TerminalProjectingSession`, Rust `fit_policy`).
        public static let terminalZoomFullScreenApps = "cmuxMobile.settings.terminalZoomFullScreenApps"
        /// Settings → Terminal → Find in Whole History (off by default; Leo, 2026-11-24: "don't
        /// unilaterally MERGE ui stuff yet ... having people be able to easily toggle"): on, Find
        /// asks the Mac's daemon (`terminal-find`) for matches in the terminal's whole history.
        public static let terminalHistoryFind = "cmuxMobile.settings.terminalHistoryFind"
        /// Settings → Transport → Ultra mode (off, auto, always); read at each dial (`FFIMacLinkDialer`).
        public static let ultra = "cmuxMobile.settings.ultra"
        /// Settings → Transport → Align Keepalives (off by default); read at each dial and by
        /// the app's keepalive timers (`KeepaliveBeat.defaultsKey`, the same key).
        public static let alignKeepalives = "cmuxMobile.settings.alignKeepalives"
        /// Settings → Transport → Direct on Wi-Fi (on by default); read at each dial
        /// (`FFIMacLinkDialer.applyLanDirectToCore`, the same key).
        public static let lanDirect = "cmuxMobile.settings.lanDirect"
        /// Settings → Transport → Tailnet (off by default): "off", "direct-only" or "on"; read at
        /// each dial (`FFIMacLinkDialer.applyTailnetCarrierToCore`, the same key; RFD 0164 T5).
        public static let tailnetCarrier = "cmuxMobile.settings.tailnetCarrier"
        /// Settings → Transport → Agent CLI Screen Changes (off by default): a Claude Code,
        /// Codex or opencode terminal comes as the cells that changed, not its PTY bytes.
        /// Read at each terminal attach (`DaemonTerminalSession.agentCLIHybridDefaultsKey`).
        public static let agentCLIHybrid = "cmuxMobile.settings.agentCLIHybrid"
        /// Settings → Transport → Mac Screen over Link (off by default): Screen Sharing shows a
        /// Mac that lists `mac-display-v1` as rd/1 on its cmux-wg link (`surface` tab `d~0`, view
        /// only) instead of the device hub's WebRTC session. Read when a Mac is opened.
        public static let macScreenOverLink = "cmuxMobile.settings.macScreenOverLink"
        /// Settings → Transport → Quiet Cloud Connections (off by default; Leo, 2026-11-24: "don't
        /// unilaterally MERGE ui stuff yet ... having people be able to easily toggle" it): on, a Cloud
        /// list or machine that answers within ``QuietStatusGate/threshold`` never shows its wait, and
        /// a short outage behind cached Cloud rows shows no alert (Leo, 2026-11-14: "i also want all our
        /// connectivity stuff to shut the fuck up and load faster/percievably load faster").
        public static let quietCloudConnect = "cmuxMobile.settings.quietCloudConnect"
        public static let dismissKeyboardAfterSend = "cmuxMobile.settings.dismissKeyboardAfterSend"
        /// Settings → Composer → Swipe Down to Collapse (off by default; `ComposerReturnTextView`).
        public static let swipeDownCollapsesComposer = "cmuxMobile.settings.swipeDownCollapsesComposer"
        public static let followUp = "cmuxMobile.settings.followUp"
        /// Settings → Composer → Session Facts (RFD 0130, off by default): `off`, `pulse` (live
        /// counters beside the context meter) or `door` (an info mark); either opens the Session card.
        public static let composerFooterFacts = "cmuxMobile.settings.composerFooterFacts"
        /// Workspaces → one line per workspace (the Mac's Compact Workspace List).
        public static let compactWorkspaceList = "cmuxMobile.settings.compactWorkspaceList"
        /// Settings → Advanced → Site Monograms on Tab Cards (taste prototype, off by default): a
        /// browser card with no picture yet shows its site's letter on the site's hue, not the globe.
        public static let tabCardMonograms = "cmuxMobile.settings.tabCardMonograms"
        /// Settings → Needs You Look (the Mac's `notifications.attention.mark`, the same values):
        /// `badge` (default) or `glow`, a waiting workspace row that glows until it is opened.
        public static let attentionMark = "cmuxMobile.settings.attentionMark"
        /// Long-press menu items the person hid (Settings → Long-Press Menus), by item id.
        public static let hiddenMenuItems = "cmuxMobile.settings.hiddenMenuItems"
    }

    /// The terminal's font size in points when the person never changed it.
    public static let defaultTerminalFontSize = 12
    /// The sizes Settings offers (and the terminal accepts).
    public static let terminalFontSizes = 9...24
    public static let defaultWrapCode = false
    public static let defaultKeyClicks = false
    public static let defaultPredictiveEcho = true
    public static let defaultPredictiveEchoFullScreen = false
    public static let defaultTerminalFitToPhone = false
    public static let defaultTerminalJumpToBottom = true
    /// Off: a shell line is not prose. On for talking to an agent CLI in
    /// prose (Leo, 2026-11-24: "an autocorect toggle in the terminal composer").
    public static let defaultTerminalComposerAutocorrect = false
    public static let defaultTerminalChatToggle = false
    /// Off again (iOS regression row 18, Aziz 2026-11-26, Leo "Ok"); `TerminalScrollDefault` holds the value Settings reads too.
    public static let defaultTerminalPlainScroll = TerminalScrollDefault.plainScroll
    public static let defaultQuietCloudConnect = false
    public static let defaultTerminalZoomFullScreenApps = false
    public static let defaultTerminalHistoryFind = true
    public static let defaultDismissKeyboardAfterSend = true
    public static let defaultTabCardMonograms = false
    /// Off until Leo picks it up (2026-11-24: "don't unilaterally MERGE ui stuff yet ... having people be able to
    /// easily toggle" it).
    public static let defaultSwipeDownCollapsesComposer = false
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

    public static func terminalComposerAutocorrect(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalComposerAutocorrect) == nil
            ? defaultTerminalComposerAutocorrect : defaults.bool(forKey: Key.terminalComposerAutocorrect)
    }

    public static func terminalJumpToBottom(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalJumpToBottom) == nil
            ? defaultTerminalJumpToBottom : defaults.bool(forKey: Key.terminalJumpToBottom)
    }

    /// Whether a Claude Code or Codex tab offers Show Chat / Show Terminal (off by default).
    public static func terminalChatToggle(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalChatToggle) == nil
            ? defaultTerminalChatToggle : defaults.bool(forKey: Key.terminalChatToggle)
    }

    /// Whether a full-screen app's drag toward older rows scrolls the rows the phone kept (off by default).
    public static func terminalPlainScroll(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalPlainScroll) == nil
            ? defaultTerminalPlainScroll : defaults.bool(forKey: Key.terminalPlainScroll)
    }

    /// Whether Cloud waits and short Cloud outages stay quiet until they last (on), or show at once
    /// (off, the default). Read each time a Cloud wait starts or a Cloud refresh fails.
    public static func quietCloudConnect(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.quietCloudConnect) == nil
            ? defaultQuietCloudConnect : defaults.bool(forKey: Key.quietCloudConnect)
    }

    /// Whether a full-screen app shows at the Mac's grid, zoomed, and fits the phone only once
    /// typed into (on), or claims the phone's grid as soon as it shows (off, the default).
    /// Read when a terminal page opens.
    public static func terminalZoomFullScreenApps(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.terminalZoomFullScreenApps) == nil
            ? defaultTerminalZoomFullScreenApps : defaults.bool(forKey: Key.terminalZoomFullScreenApps)
    }

    /// Whether Find searches the Mac's whole history for a terminal (on) or only the rows the
    /// phone holds (off, the default). Read at each search.
    public static func terminalHistoryFind(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.terminalHistoryFind) == nil
            ? defaultTerminalHistoryFind : defaults.bool(forKey: Key.terminalHistoryFind)
    }

    /// Typed characters show at once over a slow link, underlined until the
    /// remote echoes them (the terminal's `TerminalSurfacePrediction`).
    public static func predictiveEcho(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.predictiveEcho) as? Bool ?? defaultPredictiveEcho
    }

    /// Predictive echo inside full-screen apps (an agent's TUI), off by default.
    public static func predictiveEchoFullScreen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.predictiveEchoFullScreen) == nil
            ? defaultPredictiveEchoFullScreen : defaults.bool(forKey: Key.predictiveEchoFullScreen)
    }

    /// The Mac's terminal resizes to the phone (on), or keeps its size while
    /// the phone re-wraps it at its own width (off, the default;
    /// `TerminalProjectingSession`). Read when a terminal page opens.
    public static func terminalFitToPhone(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.terminalFitToPhone) == nil
            ? defaultTerminalFitToPhone : defaults.bool(forKey: Key.terminalFitToPhone)
    }

    /// A downward swipe inside a composer's text collapses it (`ComposerSwipeCollapse`). Read as each swipe begins.
    public static func swipeDownCollapsesComposer(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.swipeDownCollapsesComposer) == nil
            ? defaultSwipeDownCollapsesComposer : defaults.bool(forKey: Key.swipeDownCollapsesComposer)
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

    /// Whether browser cards with no picture show the site monogram (off by default).
    public static func tabCardMonograms(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads a launch argument's "NO"/"YES" string.
        defaults.object(forKey: Key.tabCardMonograms) == nil ? defaultTabCardMonograms : defaults.bool(forKey: Key.tabCardMonograms)
    }

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
