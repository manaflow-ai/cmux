extension TabStripModel {
    /// The tab a new tab placed right after `anchor` goes after once `anchor` left while the tab was made
    /// (Leo 2026-11-05: "if something is optimistic, then we should be able to follow along"): the nearest tab
    /// left of `anchor` (or, once the strip no longer shows it, of the new tab, shown as any of `newTab`) in the
    /// strip's order that is in `staying`. The new tab stays where it shows, as an editor's insert stays put when
    /// the character before it is deleted. Nil (the first unpinned slot) when none is.
    public func anchor(replacing anchor: TabID, newTab: Set<TabID>, staying: Set<TabID>) -> TabID? {
        let shown = orderedTabs.map(\.id)
        guard let index = shown.firstIndex(of: anchor) ?? shown.firstIndex(where: newTab.contains) else { return nil }
        return shown[..<index].last { staying.contains($0) }
    }
}
