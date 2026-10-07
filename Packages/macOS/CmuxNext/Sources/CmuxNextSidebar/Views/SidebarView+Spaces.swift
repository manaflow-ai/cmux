import AppKit
import CmuxNextDesign

// `sidebar.spacesPosition` (R109): the spaces dots sit in the footer, above
// the Settings band, or in their own row under the titlebar row.
extension SidebarView {
    /// Puts the dots in their row at `top` (`height` > 0) or in the footer.
    func placeSpaces(top: CGFloat, height: CGFloat) {
        if spacesPosition == .top {
            if profileBar.superview !== self { addSubview(profileBar) }
            profileBar.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
        } else {
            if profileBar.superview !== footer { footer.addSubview(profileBar) }
            profileBar.frame = NSRect(x: 0, y: 0, width: footer.bounds.width, height: footer.bounds.height)
        }
        profileBar.refresh()
    }
}
