extension AgentPaneNewTab {
    /// Whether `other` draws the same New Tab screen: the two differ at most in the input token (each Cmd-T has its
    /// own) and the bar's places (open tabs, workspaces, folders, actions), which the page takes in place. The page
    /// keeps its screen mounted for such an adoption (webviews newtab/adoption.ts `sameNewTabScreen`): SHORTCUT
    /// FRAMES F2, a remount moved the content twice after Cmd-T.
    public func drawsSameScreen(as other: AgentPaneNewTab) -> Bool {
        var (mine, theirs) = (self, other)
        (mine.inputToken, theirs.inputToken) = (nil, nil)
        mine.omnibar = theirs.omnibar
        return mine == theirs
    }
}
