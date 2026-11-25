import AppKit
import CmuxNextDesign

// The site-info chip and the bookmark star show at full strength by default (https://github.com/manaflow-ai/cmux/issues/50986).
// They used to fade to clear at rest and in on hover or focus (Lawrence 2026-11-21, "drastically simplify"): a person saw
// no star until they pointed at the bar, then a white one after bookmarking, and read the bar as broken ("unless i focus
// on it i see it.. otherwise its not there"). Leo asked for them hidden again (2026-11-22, "fucking hide it along with the
// favouite/left side "stuff" about icon"), so the fade is back behind `browser.omnibar.quietIcons`, off by default.
//
// The profile avatar is not in the bar at all (Leo 2026-11-22, "why do we have the profile icon here if it's always
// visible ... move it outside the omnibar"): it is the toolbar's profile button, at the toolbar's right.
extension AddressBarView {
    /// The chip and the star show: always, unless `browser.omnibar.quietIcons` is on; then only while the bar is
    /// hovered or focused.
    var showsQuietIcons: Bool {
        !suggestionEngine.display.quietIcons || pill.debugHovering || controller.state.hasFocus
    }

    /// Every path that can change the quiet icons (a page, focus, hover, bookmark or the setting) lands here; `fade`
    /// animates a hover change, nil snaps.
    func updateQuietIcons(fade: MotionFade?) {
        let alpha: CGFloat = showsQuietIcons ? 1 : 0
        for view in [chip as NSView, starButton as NSView] where view.alphaValue != alpha {
            if let fade {
                Motion.feedback.animate(fade, in: view) { view.animator().alphaValue = alpha }
            } else {
                view.alphaValue = alpha
            }
        }
    }
}
