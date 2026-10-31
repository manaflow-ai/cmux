import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace pinned inside its group shows it at rest (`sidebar.groupPinMark`; Aziz 2026-10-30: "a
/// better indicator for pinned items under a workspace group"). Before, the pin showed only on an
/// expanded row's hover (pinning-DESIGN.md), so a group's pinned members looked like the others.
/// Three looks: a small pin among the trailing marks, a small pin before the name in the group's
/// color, or a shelf (a faint wash of the group's color behind the pinned members at rest).
extension WorkspaceRowView {
    /// The look this row draws now: its setting while the workspace is pinned inside its group, else off.
    var shownGroupPin: SidebarGroupPinMark { isPinnedInGroup ? groupPinLook : .off }

    /// Sets the pin for a workspace pinned (`pinned`) inside its group; a placeholder row draws none.
    func configureGroupPin(pinned: Bool) {
        isPinnedInGroup = pinned && !isShowingPlaceholder
        groupPin.imageScaling = .scaleProportionallyDown
        groupPin.setAccessibilityElement(false)
        let look = shownGroupPin
        let side = CGFloat.iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)
        groupPin.image = look == .trailing || look == .leading ? NSImage.icon(symbol: "pin.fill", size: side) : nil
        groupPin.isHidden = groupPin.image == nil
        groupPin.themedToolTip = isPinnedInGroup && look != .off ? Strings.pinnedInGroup : nil
    }

    /// The pin's ink: the group's color before the name (the tertiary ink for a group with no
    /// color, or with `sidebar.showColors` off), the tertiary ink among the trailing marks.
    func tintGroupPin() {
        guard !groupPin.isHidden else { return }
        guard shownGroupPin == .leading, let tint = groupPinTint, !tint.isNone else {
            groupPin.setTint(Palette.textTertiary)
            return
        }
        groupPin.setTint(tint.lineColor(themed: SidebarGroupPalette.tunable.value == .theme))
    }

    /// The shelf's wash behind a pinned member at rest: the group's color, faint (the sidebar's
    /// tonal step for a group with no color). nil for any other look or row.
    var groupPinShelfFill: NSColor? {
        guard shownGroupPin == .shelf else { return nil }
        guard let tint = groupPinTint, !tint.isNone else { return Palette.sidebarStep }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return tint.lineColor(themed: SidebarGroupPalette.tunable.value == .theme).withAlphaComponent(dark ? 0.2 : 0.13)
    }

    /// Places a trailing pin left of `trailing`; returns the new trailing edge.
    func layoutTrailingGroupPin(trailing: CGFloat, cy: CGFloat) -> CGFloat {
        guard !groupPin.isHidden, shownGroupPin == .trailing else { return trailing }
        let ind = SidebarStyle.indicatorSize
        groupPin.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
        return trailing - ind - Metrics.space2
    }

    /// Places a leading pin at the title's start; returns the title's new x.
    func layoutLeadingGroupPin(textX: CGFloat, cy: CGFloat) -> CGFloat {
        guard !groupPin.isHidden, shownGroupPin == .leading else { return textX }
        let ind = SidebarStyle.indicatorSize
        groupPin.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
        return SidebarStyle.titleXAfterLeadingMark(textX)
    }
}

extension SidebarListView {
    /// `sidebar.groupPinMark` for a pinned member's row, in its group's tint (none with `sidebar.showColors` off).
    func groupPinStyle(_ row: SidebarRow) -> (SidebarGroupPinMark, GroupTint?) {
        let group = row.group.flatMap { groups[$0] ?? model.group($0) }
        return (model.groupPinMark, group.map { model.showsColors ? $0.tint : .none })
    }
}
