import AppKit
import CmuxNextDesign

// The profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2): an
// item whose info carries an avatar draws `avatarView` (the profile's
// initial or picture in a circle) instead of its glyph: the avatar alone, no
// name and no chevron (Leo and Lawrence 2026-10-20); the name shows on hover
// and the full identity in the menu its click opens.
extension SidebarItemRowView {
    /// The item draws the profile control.
    var showsAvatar: Bool { info.avatar != nil && (style.isIconOnly || style == .chip) }

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
        title.frame = .zero
        let dot = SidebarStyle.dotSize
        let circle = avatarView.convert(avatarView.circleFrame, to: self)
        badge.frame = NSRect(x: circle.maxX - dot / 2, y: circle.minY - dot / 2, width: dot, height: dot)
        return true
    }
}
