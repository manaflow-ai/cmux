import AppKit
import CmuxNextDesign

// The profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2): an
// item whose info carries an avatar draws `avatarView` (the profile's
// initial or picture in a circle) instead of its glyph. Where the footer has
// room it is a chip, the avatar and the profile's name (Leo 2026-10-20, the
// Codex desktop app's account button); in a narrow sidebar, the avatar alone.
extension SidebarItemRowView {
    /// The item draws the profile control.
    var showsAvatar: Bool { info.avatar != nil && (style.isIconOnly || style == .chip) }

    /// The profile control as a chip: the avatar, then the name.
    var isProfileChip: Bool { showsAvatar && style == .chip }

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
        if isProfileChip {
            // The circle sits as far from the chip's leading edge as from its
            // top and bottom, so the hover pill wraps it evenly.
            let d = SidebarStyle.avatarDiameter, pad = Self.profileChipPadding(rowHeight: bounds.height)
            avatarView.frame = NSRect(x: pad, y: 0, width: d, height: bounds.height)
            title.font = SidebarStyle.titleFont
            let th = ceil(title.intrinsicContentSize.height)
            let textX = pad + d + Metrics.space2
            title.frame = NSRect(x: textX, y: (bounds.height - th) / 2, width: max(0, bounds.width - Metrics.space3 - textX), height: th)
        } else {
            avatarView.frame = bounds
            title.frame = .zero
        }
        let dot = SidebarStyle.dotSize
        let circle = avatarView.convert(avatarView.circleFrame, to: self)
        badge.frame = NSRect(x: circle.maxX - dot / 2, y: circle.minY - dot / 2, width: dot, height: dot)
        return true
    }

    /// The avatar's inset from the chip's leading edge: its room above and below.
    static func profileChipPadding(rowHeight: CGFloat) -> CGFloat {
        max(Metrics.space1 / 2, (rowHeight - SidebarStyle.avatarDiameter) / 2)
    }

    /// The widest the profile chip grows; a longer name truncates.
    static let profileChipMaxWidth: CGFloat = 180

    /// Width of the profile chip showing `name` on a line `available` points
    /// wide: the avatar, the name and the padding, capped so the Search
    /// button and the spaces dots keep their room after it. Nil when the
    /// chip would not show a few letters of the name: the avatar alone.
    static func profileChipWidth(name: String, font: NSFont, rowHeight: CGFloat, available: CGFloat) -> CGFloat? {
        let pad = profileChipPadding(rowHeight: rowHeight)
        let lead = pad + SidebarStyle.avatarDiameter + Metrics.space2, trail = Metrics.space3
        let label = NSTextField(labelWithString: name)
        label.font = font
        let natural = lead + ceil(label.intrinsicContentSize.width) + Metrics.space1 + trail
        // The Search button, its gap and room for the spaces dots after it.
        let reserve = max(SidebarFooterBand.searchButtonMinSide, rowHeight) + Metrics.space2 * 2 + rowHeight
        let width = min(natural, profileChipMaxWidth, available - reserve)
        let minimum = min(natural, lead + font.pointSize * 3 + trail)
        return width >= minimum ? width.rounded(.up) : nil
    }
}
