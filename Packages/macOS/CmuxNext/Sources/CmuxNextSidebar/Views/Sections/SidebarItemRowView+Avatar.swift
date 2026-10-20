import AppKit
import CmuxNextDesign
import CmuxNextIcons

// The profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2): an
// item whose info carries an avatar draws `avatarView` (the profile's
// initial or picture in a circle) instead of its glyph. Where the footer has
// room it is one chip, avatar, name and a trailing chevron (Leo 2026-10-20,
// after the legacy footer redesign #14893); in a narrow sidebar, the avatar alone.
extension SidebarItemRowView {
    /// The item draws the profile control.
    var showsAvatar: Bool { info.avatar != nil && (style.isIconOnly || style == .chip) }

    /// The profile control as a chip: the avatar, the name, the chevron.
    var isProfileChip: Bool { showsAvatar && style == .chip }

    /// Shows the avatar or the glyph after a configure; the profile control
    /// opens a menu, so VoiceOver calls it a menu button. The chip's `icon`
    /// draws its trailing chevron.
    func applyAvatar() {
        avatarView.avatar = showsAvatar ? info.avatar : nil
        avatarView.isHidden = !showsAvatar
        icon.isHidden = showsAvatar && !isProfileChip
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
            // top and bottom, so the hover pill wraps it evenly; one chevron at
            // the trailing edge points the way the menu opens and marks where
            // the target ends (#14893).
            let d = SidebarStyle.avatarDiameter, pad = Self.profileChipPadding(rowHeight: bounds.height)
            avatarView.frame = NSRect(x: pad, y: 0, width: d, height: bounds.height)
            let cs = Self.profileChevronSide
            let scale = window?.backingScaleFactor ?? 2
            let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
            let chevronX = snap(bounds.width - Metrics.space2 - cs)
            icon.image = NSImage.icon(symbol: Self.profileChevronSymbol, size: cs)
            icon.frame = NSRect(x: chevronX, y: snap((bounds.height - cs) / 2), width: cs, height: cs)
            let font = SidebarStyle.titleFont
            title.font = font
            let th = ceil(title.intrinsicContentSize.height)
            let textX = pad + d + Metrics.space2
            let textWidth = chevronX - Metrics.space1 - textX
            // The avatar and chevron alone where the name has no room (#14893).
            title.frame = textWidth < font.pointSize ? .zero
                : NSRect(x: textX, y: (bounds.height - th) / 2, width: textWidth, height: th)
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

    /// The chip's trailing chevron: up, the way the menu opens from the footer.
    static let profileChevronSymbol = "chevron.up"
    static var profileChevronSide: CGFloat { (SidebarStyle.titleFont.pointSize * 0.75).rounded() }

    /// The widest the profile chip grows.
    static let profileChipMaxWidth: CGFloat = 220

    /// Width of the profile chip on a line `available` points wide: it fills
    /// the line's free width (#14893), less the Search button, its gaps and
    /// room for the spaces dots after it, up to `profileChipMaxWidth`. The
    /// name truncates as the line narrows, then the chip drops to the avatar
    /// and chevron; nil where even those do not fit: the avatar alone.
    static func profileChipWidth(rowHeight: CGFloat, available: CGFloat) -> CGFloat? {
        let pad = profileChipPadding(rowHeight: rowHeight)
        // Search is sized as `SidebarFooterBand.placeSearch` sizes it.
        let search = max(SidebarFooterBand.searchButtonMinSide, Metrics.sidebarRowHeight)
        let reserve = search + Metrics.space2 * 2 + rowHeight * 2
        let width = min(profileChipMaxWidth, available - reserve).rounded(.down)
        let compact = pad + SidebarStyle.avatarDiameter + Metrics.space2 + profileChevronSide + Metrics.space2
        return width >= compact ? width : nil
    }
}
