public import AppKit
public import CmuxNextDesign

// The goo look (Debug `chrome.gooMorph`, `GooMorphChrome`): the window draws the active tab of a top-row strip as a
// droplet of its pane's card, so it reads where that tab shows now and hides the tab's own fill.
extension TabStripView: GooStripSource {
    /// The selected tab's pill as it shows now (a move in flight included), in window coordinates, cut to the part
    /// the strip shows; nil with no selected tab or one scrolled out of view.
    public var selectedPillInWindow: CGRect? {
        guard window != nil, let id = model.selectedID, let cell = cells[id], let container = cell.layer.superlayer,
              let clip = tabsClip.layer else { return nil }
        // The pill fills the cell (`TabCell.layoutLayers`); a width move in flight shows in the presentation frame.
        let pill = (cell.layer.presentation() ?? cell.layer).frame
        // Moves run on the presentation tree: convert there, so a scroll in flight counts too.
        let inClip = (container.presentation() ?? container).convert(pill, to: clip.presentation() ?? clip).intersection(tabsClip.bounds)
        guard inClip.width > 1, inClip.height > 1 else { return nil }
        return tabsClip.convert(inClip, to: nil)
    }

    /// A tab move (open, close, reorder, scroll) is in flight.
    public var hasTabMovesInFlight: Bool { !movesInFlight.isEmpty }

    /// Tells the window's goo look the selected tab or the tabs' geometry changed (it ignores it while off).
    func reportSelectedPill() {
        (window?.installedContent as? any GooWindowHost)?.goo.gooStripDidChange(self)
    }
}
