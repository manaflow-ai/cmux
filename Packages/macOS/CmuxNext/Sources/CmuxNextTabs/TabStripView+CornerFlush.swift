public import AppKit
public import CmuxNextDesign

// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the selected tab is the content card's
// color and runs down to the strip's bottom, into the card, and the window root learns when the
// selected tab is the strip's first, so the card's corner under it goes square.
extension TabStripView: TabStripCorner {
    public var cornerFrameInWindow: CGRect { convert(bounds, to: nil) }

    public var selectsLeadingTab: Bool { leadsWithSelection }

    /// Gives every cell the foot below its pill (the selected one draws it) and reports a change of
    /// whether the selected tab is the first.
    func updateCornerFlush(tabY: CGFloat, tabHeight: CGFloat) {
        let on = CornerFlush.current.isOn
        let foot = on ? max(0, bounds.height - (tabY + tabHeight)) : 0
        var leads = false
        if on, tabsClip.frame.minX <= 0.5, let id = model.selectedID, let cell = cells[id], let place = placed[id] {
            let frame = cellFrame(place, isPinned: cell.item.isPinned)
            leads = frame.minX <= 0.5 && frame.maxX > 0.5
        }
        for (id, cell) in cells {
            cell.cornerFeetSkipsLeading = leads && id == model.selectedID
            cell.cornerFoot = foot
        }
        guard leads != leadsWithSelection || (on && !reportedCornerFlush) else { return }
        leadsWithSelection = leads
        reportedCornerFlush = on
        CornerFlushChrome.stripDidChange(self)
    }
}
