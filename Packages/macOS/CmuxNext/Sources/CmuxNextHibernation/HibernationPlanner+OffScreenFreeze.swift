extension HibernationPlanner.Candidate {
    /// What the freeze plan gets of this candidate, or nil when it does not freeze now.
    ///
    /// A neighbor or a page an agent drives stays awake. The page an off-screen window shows (``isActiveTab``) freezes
    /// only with `freezesShownPages` (feature `offScreenWindowPageFreeze`) and when its tab follows no visibility node,
    /// and then at once: Chrome hides the WebContents of an occluded window in its own turn
    /// (content/browser/web_contents/web_contents_impl.cc `UpdateWebContentsVisibility`), and before fork API 37 the
    /// freeze is the only hide cmux can send. A tab that follows its node was hidden by the window node already.
    ///
    /// - Parameters:
    ///   - freezesShownPages: The page an off-screen window shows may freeze.
    ///   - followsNode: Its tab follows its visibility node, so Chromium heard the window's hide.
    ///   - freezeSeconds: The hidden pages' freeze delay (`browser.freezeHiddenTabs`); nil freezes nothing.
    package func freezeCandidate(freezesShownPages: Bool, followsNode: Bool, freezeSeconds: Double?) -> Self? {
        guard !isNeighbor, !isAgentDriving else { return nil }
        guard isActiveTab else { return self }
        guard freezesShownPages, !followsNode, let freezeSeconds else { return nil }
        var due = self
        due.hiddenFor = max(hiddenFor, freezeSeconds)
        return due
    }
}
