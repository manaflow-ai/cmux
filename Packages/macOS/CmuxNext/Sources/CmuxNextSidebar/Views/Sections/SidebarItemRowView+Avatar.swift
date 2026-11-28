import AppKit

// The profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2): an
// icon-only item whose info carries an avatar draws `avatarView` (the
// profile's initial in a circle and a chevron) instead of its glyph.
extension SidebarItemRowView {
    /// The item draws the profile control.
    var showsAvatar: Bool { info.avatar != nil && style.isIconOnly }

    /// Shows the avatar or the glyph after a configure; the profile control
    /// opens a menu, so VoiceOver calls it a menu button.
    func applyAvatar() {
        avatarView.avatar = showsAvatar ? info.avatar : nil
        avatarView.isHidden = !showsAvatar
        icon.isHidden = showsAvatar
        setAccessibilityRole(showsAvatar ? .menuButton : .button)
    }

    /// Lays out the profile control in `bounds`; false (and no avatar
    /// frame) for every other item.
    func layoutAvatar(in bounds: NSRect) -> Bool {
        guard showsAvatar else {
            avatarView.frame = .zero
            return false
        }
        avatarView.frame = bounds
        let dot = SidebarStyle.dotSize, circle = avatarView.circleFrame
        badge.frame = NSRect(x: circle.maxX - dot / 2, y: circle.minY - dot / 2, width: dot, height: dot)
        title.frame = .zero
        return true
    }
}
