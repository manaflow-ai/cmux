extension CreationInputBuffer {
    /// The actions of a new-tab key: a tab in the focused pane (New Tab, New Terminal Tab, New Browser Tab).
    public static let newTabCommands: Set<String> = ["newTab.default", "newSurface", "openBrowser", "openBrowser.webkit", "openBrowser.chromium"]

    /// Whether a key that runs `command` is a new-tab key (Ctrl-`, Cmd-T, Cmd-Shift-L) pressed on a stand-in tab this
    /// hold is still making: it acts now, as a close key does, and never waits for that tab's daemon answer (Lawrence
    /// 2026-11-13: "holding down a key to create new tab or new browser is also slow"). The pane already shows and
    /// selects the stand-in of the press before it, so the new tab goes right after it and gets its own lane for the keys
    /// typed next; the keys already held keep their lanes. Held, the key ran once per daemon answer, focus and first frame
    /// of the tab before it, and a replayed one named that tab as its target, which put its tab at the end of the strip.
    /// Not for a creation that shows no tab of its own (a split or a workspace on its way): its keys wait as before.
    /// - Parameters:
    ///   - command: the action the key's shortcut resolves to, nil for a key that is no shortcut.
    ///   - tab: the tab the key was typed on when it is a stand-in (a provisional tab), else nil.
    public func opensTabNow(_ command: String?, onStandIn tab: String?) -> Bool {
        guard let command, let tab, Self.newTabCommands.contains(command) else { return false }
        return lane(focusedTab: tab) != nil && !isClosing(tab: tab)
    }
}
