extension AgentPaneNewTab {
    /// Whether `other` draws the same New Tab screen: the two differ at most in the input token (each Cmd-T has its
    /// own), the bar's places (open tabs, workspaces, folders, actions), which the page takes in place, and the warm
    /// chat list, which the page reads only at its first load. The page
    /// keeps its screen mounted for such an adoption (webviews newtab/adoption.ts `sameNewTabScreen`): SHORTCUT
    /// FRAMES F2, a remount moved the content twice after Cmd-T.
    public func drawsSameScreen(as other: AgentPaneNewTab) -> Bool {
        var (mine, theirs) = (self, other)
        (mine.inputToken, theirs.inputToken, mine.warm, theirs.warm) = (nil, nil, nil, nil)
        mine.omnibar = theirs.omnibar
        return mine == theirs
    }
}
