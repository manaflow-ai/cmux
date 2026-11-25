import AppKit
import CmuxNextDesign

// The site-info chip and the bookmark star always show (https://github.com/manaflow-ai/cmux/issues/50986). They used to
// fade to clear at rest and in on hover or focus (Lawrence 2026-11-21, "drastically simplify"): a person saw no star
// until they pointed at the bar, then a white one after bookmarking, and read the bar as broken ("unless i focus on it i
// see it.. otherwise its not there"). They now draw at full strength in every state, in the bar's ink (`OmnibarInk`).
//
// The profile avatar is quiet (Leo 2026-11-22, "why do we have the profile icon here if it's always visible ... hide it
// along with the favouite/left side \"stuff\" about icon"): a tab's profile does not change while you read the page, so
// it is clear at rest and shows when the pointer is on the bar or the bar has the keyboard. It keeps its room, so its
// coming and going moves no text.
extension AddressBarView {
    /// Whether the quiet profile avatar shows: the pointer is on the bar, or the bar has the keyboard.
    var showsQuietIcons: Bool { pill.debugHovering || controller.state.hasFocus }

    /// Shows the chip and the star at full strength, and fades the profile avatar in or out; `fade` nil sets it at once
    /// (a page or focus change). Every path that once faded the quiet icons (a page, focus, hover or bookmark change)
    /// still lands here.
    func updateQuietIcons(fade: MotionFade?) {
        for view in [chip as NSView, starButton as NSView] where view.alphaValue != 1 {
            view.alphaValue = 1
        }
        let profileAlpha: CGFloat = showsQuietIcons ? 1 : 0
        guard profileBadgeView.alphaValue != profileAlpha else { return }
        let avatar: NSView = profileBadgeView
        if let fade {
            Motion.feedback.animate(fade, in: avatar) { avatar.animator().alphaValue = profileAlpha }
        } else {
            avatar.alphaValue = profileAlpha
        }
    }
}
