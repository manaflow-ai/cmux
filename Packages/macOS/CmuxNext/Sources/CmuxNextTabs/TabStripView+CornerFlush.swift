public import AppKit
public import CmuxNextDesign

// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the selected tab is the content card's
// color and runs down to the strip's bottom, into the card, and the window root learns when the
// selected tab is the strip's first, so the card's corner under it goes square.
extension TabStripView: TabStripCorner {
    public var cornerFrameInWindow: CGRect { convert(bounds, to: nil) }

    public var selectsLeadingTab: Bool { leadsWithSelection }

    public func setRunsIntoCard(_ runs: Bool) {
        guard runs != runsIntoCard else { return }
        runsIntoCard = runs
        needsLayout = true
    }

    /// Gives every cell the foot below its pill (the selected one draws it) and reports whether the
    /// selected tab is the first. A layout pass: a selection alone calls ``reportCornerLead()``.
    func updateCornerFlush(tabY: CGFloat, tabHeight: CGFloat) {
        // Bottom tabs have no card under them (`CornerFlushChrome.apply`): the selected tab stays a pill.
        // A strip inside the card (a lower split pane's, ``setRunsIntoCard(_:)``) keeps the pill too.
        let runsDown = isPaneTabRow && runsIntoCard && CornerFlush.current.isOn && DesignSettings.shared.tabBarPosition != .bottom
        let foot = runsDown ? max(0, bounds.height - (tabY + tabHeight)) : 0
        for cell in cells.values { cell.cornerFoot = foot }
        reportCornerLead()
    }

    /// Reports to the window root whether the selected tab is the strip's first, on its leading edge,
    /// so the card's corner under it squares or rounds in the same pass as the tab's fill. O(1): only
    /// the selected tab is read, so a selection change costs the same at any tab count.
    func reportCornerLead() {
        guard isPaneTabRow else { return }
        let on = CornerFlush.current.isOn
        var leads = false
        if on, tabsClip.frame.minX <= 0.5, let id = model.selectedID, let cell = cells[id], let place = placed[id] {
            let frame = cellFrame(place, isPinned: cell.item.isPinned)
            leads = frame.minX <= 0.5 && frame.maxX > 0.5
        }
        if let id = model.selectedID { cells[id]?.cornerFeetSkipsLeading = leads }
        // While it leads, every layout reports too: the strip may have reached the card's corner since. A
        // strip that moved in the window reports its new place (the chrome checks the tab row is whole).
        let frame = on ? cornerFrameInWindow : nil
        guard leads != leadsWithSelection || leads || (on && !reportedCornerFlush) || frame != reportedCornerFrame else { return }
        leadsWithSelection = leads
        reportedCornerFrame = frame
        // Not yet in a window root's tree: report again on the next layout.
        reportedCornerFlush = CornerFlushChrome.stripDidChange(self) && on
    }
}
