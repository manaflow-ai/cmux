public import CmuxNextActions

/// Who gets a cmux shortcut pressed while a Chromium page has the keyboard (CMUX-641: Linear's Cmd-K opened cmux
/// Search Chats). Chrome's model (Lawrence and Austin 2026-11-19, "copy UTM"): the page gets the key first, and cmux
/// runs the action only when Chromium reports the key unhandled (`cmux_shim_set_unhandled_key_handler`), so a page
/// that does not use the key still runs the cmux action. ``cmuxKept`` keys and the system tier stay with cmux, as
/// Chrome keeps its reserved tab and window keys. cmux mode (the page's browser focus mode flag, toggled with
/// Cmd-Opt-Return) gives every shortcut back to cmux, Find and its neighbors aside.
public nonisolated struct PageShortcutRoute: Equatable, Sendable {
    /// The action the key runs in cmux.
    public var id: ActionID
    public var tier: ActionKeyTier

    public init(id: ActionID, tier: ActionKeyTier) {
        self.id = id
        self.tier = tier
    }

    /// The actions a page gets first in cmux mode too: Find and its neighbors (Lawrence 2026-11-11; Google Sheets
    /// takes Cmd-F for its own search, 2026-10-23).
    public static let pageOwnable: Set<ActionID> = ["find", "findNext", "findPrevious", "browser.findPrevious", "useSelectionForFind"]

    /// Keys that stay with cmux while other shortcuts go to the page first: Chrome's reserved tab keys (new tab,
    /// reopen tab, next and previous tab), the address bar (Cmd-L, always the omnibar: Austin 2026-11-19), Cmd-1 to
    /// Cmd-9, and Ghostty's pane keys, reserved in every pane (schemas/keybindings/ghostty-reserved-keys.json:
    /// Cmd-D, Cmd-Opt-arrows, Ctrl-Cmd-arrows, Shift-Cmd-Return). System actions (Cmd-W, Cmd-Q, Cmd-N, Cmd-Shift-P,
    /// Cmd-Opt-Return) stay by their tier.
    public static let cmuxKept: Set<ActionID> = [
        "newTab", "newTab.default", "newBrowserWorkspace", "openBrowser", "reopenClosedBrowserPanel", "nextSurface",
        "prevSurface", "nextSidebarTab", "prevSidebarTab", "selectWorkspaceByNumber", "selectSurfaceByNumber", "focusLeft",
        "focusRight", "focusUp", "focusDown", "splitRight", "splitDown", "resizePaneLeft", "resizePaneRight",
        "resizePaneUp", "resizePaneDown", "toggleSplitZoom", "focusBrowserAddressBar", "focusLocation",
    ]

    /// Whether the key waits for the page instead of running first: the page reports the keys it leaves unhandled
    /// (`pageHasKeys`), the action is not a system action, and it is one of ``pageOwnable`` or, outside cmux mode,
    /// any but ``cmuxKept``.
    public func offersToPage(pageHasKeys: Bool, cmuxMode: Bool) -> Bool {
        guard pageHasKeys, tier != .system else { return false }
        return Self.pageOwnable.contains(id) || (!cmuxMode && !Self.cmuxKept.contains(id))
    }

    /// Whether the page taking this key is news the person may not expect: a cmux app shortcut (not Find, which pages
    /// always had first, and not a browser key such as Reload or Back, which does the same job in both). The one-time
    /// cmux mode notice shows for such a key.
    public var isAppShortcut: Bool { tier == .navigation && !Self.pageOwnable.contains(id) && !Self.cmuxKept.contains(id) }
}
