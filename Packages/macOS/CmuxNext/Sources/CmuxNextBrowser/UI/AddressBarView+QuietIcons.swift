import AppKit
import CmuxNextDesign

// The site-info chip and the bookmark star always show (https://github.com/manaflow-ai/cmux/issues/50986). They used to
// fade to clear at rest and in on hover or focus (Lawrence 2026-11-21, "drastically simplify"): a person saw no star
// until they pointed at the bar, then a white one after bookmarking, and read the bar as broken ("unless i focus on it i
// see it.. otherwise its not there"). They now draw at full strength in every state, in the bar's ink (`OmnibarInk`).
//
// The profile avatar is not in the bar at all (Leo 2026-11-22, "why do we have the profile icon here if it's always
// visible ... move it outside the omnibar"): it is the toolbar's profile button, at the toolbar's right.
extension AddressBarView {
    /// Shows the chip and the star at full strength. Kept as one call so every path that once faded them (a page,
    /// focus, hover or bookmark change) still lands here; `fade` is ignored.
    func updateQuietIcons(fade: MotionFade?) {
        for view in [chip as NSView, starButton as NSView] where view.alphaValue != 1 {
            view.alphaValue = 1
        }
    }
}
