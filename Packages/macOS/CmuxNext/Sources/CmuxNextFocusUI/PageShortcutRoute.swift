public import CmuxNextActions

/// Who gets a cmux shortcut pressed while a Chromium page has the keyboard (`browser.pageShortcuts`, CMUX-641: Linear's
/// Cmd-K opened cmux Search Chats). `page`: the page first, and cmux runs the action only when Chromium reports the key
/// unhandled (`cmux_shim_set_unhandled_key_handler`). `cmux`: cmux first but Find and its neighbors (Lawrence
/// 2026-11-11; Google Sheets takes Cmd-F for its own search, 2026-10-23). `ask` (the default): as `cmux`, but the first
/// app shortcut pressed on a site waits for the person's answer for that site, or every site (Austin and Lucas
/// 2026-11-18; `browser.pageShortcutSites`). The system tier, Chrome's reserved tab keys and Ghostty's pane keys stay
/// with cmux in every mode; browser focus mode gives the page every key (the key router asks this only outside it).
public nonisolated struct PageShortcutRoute: Equatable, Sendable {
    /// The action the key runs in cmux.
    public var id: ActionID
    public var tier: ActionKeyTier

    public init(id: ActionID, tier: ActionKeyTier) {
        self.id = id
        self.tier = tier
    }

    /// The actions a page may own in every mode: Find and its neighbors.
    public static let pageOwnable: Set<ActionID> = ["find", "findNext", "findPrevious", "browser.findPrevious", "useSelectionForFind"]

    /// Keys that stay with cmux while other shortcuts go to the page first: Chrome's reserved tab keys (new tab, reopen
    /// tab, next and previous tab), Cmd-1 to Cmd-9, and Ghostty's pane keys, reserved in every pane
    /// (schemas/keybindings/ghostty-reserved-keys.json: Cmd-D, Cmd-Opt-arrows, Ctrl-Cmd-arrows, Shift-Cmd-Return).
    /// System actions (Cmd-W, Cmd-Q, Cmd-N, Cmd-Shift-P) stay by their tier.
    public static let cmuxKept: Set<ActionID> = [
        "newTab", "newTab.default", "newBrowserWorkspace", "openBrowser", "reopenClosedBrowserPanel", "nextSurface",
        "prevSurface", "nextSidebarTab", "prevSidebarTab", "selectWorkspaceByNumber", "selectSurfaceByNumber", "focusLeft",
        "focusRight", "focusUp", "focusDown", "splitRight", "splitDown", "resizePaneLeft", "resizePaneRight",
        "resizePaneUp", "resizePaneDown", "toggleSplitZoom",
    ]

    /// Whether the key waits for the page instead of running first: the page reports the keys it leaves unhandled
    /// (`pageHasKeys`), and the action is one of ``pageOwnable``, or, with `browser.pageShortcuts` `page`
    /// (`pageFirst`), any but the system tier and ``cmuxKept``.
    public func offersToPage(pageHasKeys: Bool, pageFirst: Bool) -> Bool {
        guard pageHasKeys, tier != .system else { return false }
        return Self.pageOwnable.contains(id) || (pageFirst && !Self.cmuxKept.contains(id))
    }

    /// Whether `ask` asks about the key: an app shortcut (navigation tier) `page` would send to the page first. Browser
    /// keys (Reload, Back, Zoom) do the same job in both, and Find is the page's already.
    public func asks(pageHasKeys: Bool) -> Bool {
        tier == .navigation && !Self.pageOwnable.contains(id) && offersToPage(pageHasKeys: pageHasKeys, pageFirst: true)
    }
}
