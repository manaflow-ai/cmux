extension TabStripModel {
    /// The tab a new tab placed right after `anchor` goes after once `anchor` left while the tab was made
    /// (Leo 2026-11-05: "if something is optimistic, then we should be able to follow along"): the nearest tab
    /// left of `anchor` that is in `staying`, in the strip's order (or, once the strip no longer shows `anchor`,
    /// left of the new tab, shown as any of `newTab`), else in `opened`, the pane's order when the open began
    /// (an open with no stand-in shows nothing to rebase on). The new tab stays where it shows, as an editor's
    /// insert stays put when the character before it is deleted. Nil (the first unpinned slot) when none is.
    public func anchor(replacing anchor: TabID, newTab: Set<TabID>, staying: Set<TabID>, opened: [TabID] = []) -> TabID? {
        let shown = orderedTabs.map(\.id)
        if let index = shown.firstIndex(of: anchor) ?? shown.firstIndex(where: newTab.contains) {
            return shown[..<index].last { staying.contains($0) }
        }
        guard let index = opened.firstIndex(of: anchor) else { return nil }
        return opened[..<index].last { staying.contains($0) }
    }
}
