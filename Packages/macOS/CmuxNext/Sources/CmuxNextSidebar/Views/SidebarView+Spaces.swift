import AppKit

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
            let helpWidth = helpButton.isHidden ? 0 : SidebarStyle.footerHeight + Metrics.space2
            profileBar.frame = NSRect(x: 0, y: 0, width: max(0, footer.bounds.width - helpWidth), height: footer.bounds.height)
        }
        profileBar.refresh()
    }
}
