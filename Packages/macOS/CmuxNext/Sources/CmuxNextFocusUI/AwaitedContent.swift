/// The focused content that a key typed now would miss (REOPEN-F4): the focus names it, but its pane does not show it
/// yet. A reopened window comes forward before its panes' surfaces, which come one a frame, and a workspace shown cold
/// makes its surfaces again. The window's key hold waits for it (`CreationInputCoordinator`).
public struct AwaitedContent: Equatable, Sendable {
    /// What the focus names.
    public enum Kind: Equatable, Sendable {
        case terminal
        /// A browser tab: Chromium makes its page after the window shows (an async start at a relaunch).
        case browser
    }

    /// The focused tab.
    public let tab: String
    public let kind: Kind

    /// Its held keys go to its terminal by a lane (also at the hold's bound, by the daemon when its view never came).
    public var hasTerminalLane: Bool { kind == .terminal }

    public init(tab: String, kind: Kind) {
        (self.tab, self.kind) = (tab, kind)
    }

    /// The focused pane's controller now.
    public struct Pane: Equatable, Sendable {
        /// The tab its strip selects.
        public var selectedTab: String?
        /// The tab whose content it shows, and that content's kind (nil: none, or another kind).
        public var shownTab: String?
        public var shownKind: Kind?
        /// The selected tab is a terminal that will draw (not a dead one).
        public var selectedIsLiveTerminal: Bool
        /// The shown browser content's page is ready for keys (``BrowserTab/pageReady``): only then does a key reach it.
        public var shownPageReady: Bool

        public init(selectedTab: String?, shownTab: String?, shownKind: Kind?, selectedIsLiveTerminal: Bool, shownPageReady: Bool = true) {
            (self.selectedTab, self.shownTab, self.shownKind, self.selectedIsLiveTerminal) = (selectedTab, shownTab, shownKind, selectedIsLiveTerminal)
            self.shownPageReady = shownPageReady
        }
    }

    /// The content a key typed now would miss: the focus names `tab` of `kind`, and its pane (`pane`; nil: the pane has
    /// no controller yet, `paneInTopology` says whether the focus's topology lists it) does not show it. Nil otherwise.
    public static func awaited(_ kind: Kind, tab: String, pane: Pane?, paneInTopology: Bool) -> AwaitedContent? {
        if let pane {
            // The common case first (every key-down asks): the content shows.
            if pane.shownTab == tab, pane.shownKind == kind, kind != .browser || pane.shownPageReady { return nil }
            guard pane.selectedTab == tab, kind == .browser || pane.selectedIsLiveTerminal else { return nil }
        } else if !paneInTopology {
            return nil
        }
        return AwaitedContent(tab: tab, kind: kind)
    }

    /// The app actions that need the focused page itself (its address bar): they wait for it in a page hold.
    public static let pageActions: Set<String> = ["focusLocation", "focusBrowserAddressBar", "browser.focusSearch"]

    /// Whether a page hold keeps a key: every key once one is held (the order stays), a plain key and a chord no app
    /// binding takes (the page's own keys), and a page action (``pageActions``). An app shortcut that does not need the
    /// page (Ctrl-Tab, Cmd-T, Cmd-1) acts at once while the hold is empty: a cold tab passed on the way never delays it.
    /// `pageCreated`: Chromium created the page, so a page action (its address bar) needs no document: with nothing held, it goes on.
    public static func pageHoldKeeps(isChord: Bool, holdIsEmpty: Bool, command: String?, pageCreated: Bool = false) -> Bool {
        !holdIsEmpty || !isChord || command.map { pageActions.contains($0) && !pageCreated } ?? true
    }
}
